// p2p-worker.js —— B 通道：Cloudflare Workers WebSocket 中继
//
// 部署（免费额度足够：Workers 10 万请求/天，长连接只算 1 次请求）：
//   1) npm i -g wrangler && wrangler login
//   2) 把本文件与 wrangler.toml 放进同一个空目录
//   3) wrangler deploy
//   4) 得到 https://p2p-relay.<你的子域>.workers.dev
//   5) 客户端填 wss://p2p-relay.<你的子域>.workers.dev + 同一个房间号
//
// 协议：同房间的所有连接互为对端，任何一帧都转发给房间内其他连接。
// 服务端只做转发，不看内容；加密由客户端负责（后续接 TAP 时套 XChaCha20）。

export class Room {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.sessions = new Set();
  }

  meta() {
    return JSON.stringify({ t: "peers", peers: this.sessions.size });
  }

  broadcast(from, data) {
    for (const s of this.sessions) {
      if (s === from) continue;
      try {
        s.send(data);
      } catch {
        this.sessions.delete(s);
      }
    }
  }

  broadcastMeta() {
    const m = this.meta();
    for (const s of this.sessions) {
      try {
        s.send(m);
      } catch {
        this.sessions.delete(s);
      }
    }
  }

  async fetch(request) {
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    this.sessions.add(server);
    try {
      server.send(this.meta());
    } catch {}

    server.addEventListener("message", (ev) => {
      // 心跳不转发，只回 meta
      if (typeof ev.data === "string" && ev.data.includes('"t":"ping"')) return;
      this.broadcast(server, ev.data);
    });

    const drop = () => {
      if (this.sessions.delete(server)) this.broadcastMeta();
    };
    server.addEventListener("close", drop);
    server.addEventListener("error", drop);

    this.broadcastMeta();
    return new Response(null, { status: 101, webSocket: client });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const m = url.pathname.match(/^\/room\/(.+)$/);
    if (!m) {
      return new Response(
        "P2P relay\n\nusage: wss://<worker>/room/<room-id>\n",
        { status: 200, headers: { "content-type": "text/plain; charset=utf-8" } }
      );
    }
    if ((request.headers.get("Upgrade") || "").toLowerCase() !== "websocket") {
      return new Response("websocket required", { status: 426 });
    }
    const id = env.ROOMS.idFromName(m[1]);
    return env.ROOMS.get(id).fetch(request);
  },
};
