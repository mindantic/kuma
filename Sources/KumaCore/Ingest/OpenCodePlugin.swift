import Foundation

public enum OpenCodePlugin {
    public static let placeholder = "__KUMA_HOOK__"

    public static let source = #"""
import { spawn } from "node:child_process";

const KUMA_HOOK = "__KUMA_HOOK__";
const UNSET = "__KUMA_" + "HOOK__";
const SUMMARY_PREFIX = "kuma-summary";
const CALL_TIMEOUT_MS = 3000;

const titles = new Map();
const parents = new Map();
const lastStatus = new Map();
let v2Active = false;

function pick(...values) {
  for (const v of values) {
    if (typeof v === "string" && v.trim()) return v.trim();
  }
  return undefined;
}

function remember(map, key, value) {
  if (!key) return;
  if (map.size >= 512) map.delete(map.keys().next().value);
  map.set(key, value);
}

function isGuarded() {
  return Boolean(process.env.KUMA_SUMMARY);
}

function send(event, payload) {
  try {
    if (isGuarded() || !KUMA_HOOK || KUMA_HOOK === UNSET) return;
    const child = spawn(KUMA_HOOK, ["opencode", event], {
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
      env: process.env,
    });
    child.on("error", () => {});
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(payload));
    child.unref();
  } catch {}
}

function withTimeout(promise) {
  return Promise.race([
    Promise.resolve(promise),
    new Promise((resolve) => setTimeout(() => resolve(undefined), CALL_TIMEOUT_MS)),
  ]);
}

async function tryCall(fn, variants) {
  if (typeof fn !== "function") return undefined;
  for (const args of variants) {
    try {
      const result = await withTimeout(fn(...args));
      if (result === undefined || result === null) continue;
      if (typeof result === "object" && ("data" in result || "error" in result)) {
        if (result.data !== undefined && result.data !== null) return result.data;
        continue;
      }
      return result;
    } catch {}
  }
  return undefined;
}

async function sessionInfo(client, id) {
  const session = client?.session;
  const get = session?.get?.bind(session);
  return tryCall(get, [[{ path: { id } }], [{ sessionID: id }], [id]]);
}

function messageList(data) {
  if (Array.isArray(data)) return data;
  if (Array.isArray(data?.messages)) return data.messages;
  if (Array.isArray(data?.items)) return data.items;
  if (Array.isArray(data?.data)) return data.data;
  return [];
}

async function lastAssistant(client, id) {
  const session = client?.session;
  const messages = session?.messages?.bind(session);
  const data = await tryCall(messages, [[{ path: { id } }], [{ sessionID: id }], [id]]);
  const list = messageList(data);
  for (let i = list.length - 1; i >= 0; i--) {
    const entry = list[i];
    const info = entry?.info ?? entry;
    if (info?.role !== "assistant") continue;
    const parts = Array.isArray(entry?.parts) ? entry.parts : Array.isArray(info?.parts) ? info.parts : [];
    const text = parts
      .filter((p) => p && p.type === "text" && typeof p.text === "string" && !p.synthetic && !p.ignored)
      .map((p) => p.text)
      .join("\n")
      .trim() || pick(info?.text, entry?.text) || "";
    const model = pick(
      info?.modelID,
      info?.model?.modelID,
      info?.model?.id,
      typeof info?.model === "string" ? info.model : undefined,
    );
    const provider = pick(info?.providerID, info?.model?.providerID);
    if (text || model) {
      return { text, model: model ? (provider && !model.includes("/") ? `${provider}/${model}` : model) : undefined };
    }
  }
  return {};
}

async function resolveSession(client, id) {
  let title = titles.get(id);
  let parent = parents.get(id);
  let directory;
  if (title === undefined || parent === undefined) {
    const info = await sessionInfo(client, id);
    title = pick(info?.title) ?? title ?? "";
    parent = pick(info?.parentID) ?? "";
    directory = pick(info?.directory);
    remember(titles, id, title);
    remember(parents, id, parent);
  }
  return { title, parent, directory };
}

function questionText(props) {
  const list = Array.isArray(props?.questions) ? props.questions : [];
  const text = list.map((q) => pick(q?.question, q?.header)).filter(Boolean).join("\n");
  return text || pick(props?.question, props?.title, props?.message);
}

function permissionText(props) {
  const action = pick(props?.permission, props?.action, props?.type, props?.title);
  const patterns = props?.patterns ?? props?.resources ?? props?.pattern;
  const target = Array.isArray(patterns) ? patterns.filter((p) => typeof p === "string").join(", ") : pick(patterns);
  const description = pick(props?.metadata?.description, props?.metadata?.command, props?.title);
  return [action, description && description !== action ? description : undefined, target]
    .filter(Boolean)
    .join(": ") || "Permission requested";
}

function errorText(props) {
  const err = props?.error;
  return pick(err?.data?.message, err?.message, typeof err === "string" ? err : undefined, err?.name) || "Session error";
}

async function handle(client, fallbackDirectory, event) {
  if (isGuarded() || !event || typeof event.type !== "string") return;
  const type = event.type
    .replace("permission.v2.asked", "permission.asked")
    .replace("question.v2.asked", "question.asked");
  const props = event.properties || {};

  if (type === "session.created" || type === "session.updated") {
    const info = props.info || {};
    if (!info.id) return;
    remember(titles, info.id, pick(info.title) ?? "");
    remember(parents, info.id, pick(info.parentID) ?? "");
    if (type === "session.created" && !info.parentID && !(info.title || "").startsWith(SUMMARY_PREFIX)) {
      send("session.created", { session_id: info.id, directory: pick(info.directory) || fallbackDirectory, title: pick(info.title) });
    }
    return;
  }

  if (type === "session.deleted") {
    const info = props.info || {};
    if (!info.id || info.parentID) return;
    send("session.deleted", { session_id: info.id, directory: pick(info.directory) || fallbackDirectory, title: pick(info.title) });
    titles.delete(info.id);
    parents.delete(info.id);
    lastStatus.delete(info.id);
    return;
  }

  const handled = ["session.idle", "session.status", "session.error", "permission.asked", "permission.updated", "question.asked"];
  if (!handled.includes(type)) return;

  const sessionID = pick(props.sessionID, props.info?.id);
  if (!sessionID) {
    if (type === "session.error") send("session.error", { session_id: "", directory: fallbackDirectory, detail: errorText(props) });
    return;
  }

  const statusType = type === "session.status" ? pick(props.status?.type, props.status) : type === "session.idle" ? "idle" : undefined;
  if (statusType) {
    const previous = lastStatus.get(sessionID);
    if (type === "session.status" && statusType === "idle") return;
    if (statusType === previous) return;
    remember(lastStatus, sessionID, statusType);
  }

  const { title, parent, directory } = await resolveSession(client, sessionID);
  if ((title || "").startsWith(SUMMARY_PREFIX)) return;
  const root = parent || sessionID;
  let rootTitle = title;
  if (parent) rootTitle = (await resolveSession(client, parent)).title;
  if ((rootTitle || "").startsWith(SUMMARY_PREFIX)) return;

  const base = {
    session_id: root,
    directory: directory || fallbackDirectory,
    title: rootTitle || undefined,
  };
  if (parent) base.agent_type = "subagent";

  if (type === "session.status") {
    if (parent) return;
    send("session.status", { ...base, status: statusType });
    return;
  }
  if (type === "session.idle") {
    const last = await lastAssistant(client, sessionID);
    send("session.idle", { ...base, model: last.model, message: last.text || undefined });
    return;
  }
  if (type === "session.error") {
    send("session.error", { ...base, detail: errorText(props) });
    return;
  }
  if (type === "question.asked") {
    send("question.asked", { ...base, detail: questionText(props) });
    return;
  }
  send(type, { ...base, detail: permissionText(props) });
}

async function sessionInfo(ctx, sessionID) {
  const session = ctx?.session;
  const get = typeof session?.get === "function" ? session.get.bind(session) : undefined;
  const info = await tryCall(get, [[{ sessionID }], [{ id: sessionID }], [sessionID]]);
  return {
    title: pick(info?.title),
    directory: pick(info?.directory, info?.location?.directory, info?.path?.cwd, info?.cwd),
    parent: pick(info?.parentID, info?.parentId),
  };
}

function v2Model(model) {
  if (!model || typeof model !== "object") return pick(model);
  const id = pick(model.id, model.modelID);
  const provider = pick(model.providerID);
  return id && provider ? `${provider}/${id}` : id;
}

async function setupV2(ctx) {
  const noop = async () => {};
  if (typeof ctx?.ui?.router?.current === "function") return noop;
  if (typeof ctx?.event?.subscribe !== "function" || isGuarded()) return noop;
  v2Active = true;
  const controller = new AbortController();
  const state = new Map();
  const of = (id) => {
    let s = state.get(id);
    if (!s) {
      s = {};
      remember(state, id, s);
    }
    return s;
  };
  const emit = async (event, sessionID, extra) => {
    const s = of(sessionID);
    if (!s.info) s.info = await sessionInfo(ctx, sessionID);
    const title = pick(s.title, s.info.title);
    if ((title || "").startsWith(SUMMARY_PREFIX)) return;
    const payload = { session_id: sessionID, directory: pick(s.info.directory, s.directory) || process.cwd(), title, model: s.model, ...extra };
    if (s.info.parent) {
      if (event !== "session.idle") return;
      payload.session_id = s.info.parent;
      payload.agent_type = "subagent";
    }
    send(event, payload);
  };
  const consume = async () => {
    for await (const input of ctx.event.subscribe({ signal: controller.signal })) {
      try {
        const type = input?.type;
        const data = input?.data || {};
        const id = pick(data.sessionID, data.form?.sessionID);
        if (!id) continue;
        const s = of(id);
        if (data.directory) s.directory = pick(data.directory);
        if (type === "session.renamed") s.title = pick(data.title, data.name, s.title);
        else if (type === "session.step.started") s.model = v2Model(data.model) || s.model;
        else if (type === "session.text.started") s.text = "";
        else if (type === "session.text.ended") s.text = pick(data.text, s.text);
        else if (type === "session.execution.started") {
          s.text = "";
          await emit("session.status", id, { status: "busy" });
        } else if (type === "session.execution.succeeded") await emit("session.idle", id, { message: s.text || undefined });
        else if (type === "session.execution.failed") await emit("session.error", id, { detail: pick(data.error?.message, data.message, "The run failed") });
        else if (type === "permission.asked") await emit("permission.asked", id, { detail: permissionText({ ...data, permission: data.action, patterns: data.resources }) });
        else if (type === "form.created") await emit("question.asked", id, { detail: pick(data.form?.title, data.form?.fields?.[0]?.description, data.form?.fields?.[0]?.title) });
      } catch {}
    }
  };
  consume().catch(() => {});
  return async () => controller.abort();
}

export const Kuma = async (ctx) => {
  const client = ctx?.client;
  const directory = typeof ctx?.directory === "string" ? ctx.directory : process.cwd();
  return {
    event: async (input) => {
      try {
        if (isGuarded() || v2Active) return;
        handle(client, directory, input?.event).catch(() => {});
      } catch {}
    },
  };
};

export default process.env.KUMA_OPENCODE_PLUGIN_API === "v1" ? Kuma : {
  id: "kuma",
  server: Kuma,
  setup: setupV2,
};
"""#

    public static func rendered(hookBinary: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [hookBinary], options: [.withoutEscapingSlashes])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        let literal = String(array.dropFirst().dropLast())
        return source.replacingOccurrences(of: "\"" + placeholder + "\"", with: literal)
    }
}
