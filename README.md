# LeechTunnel

**Lightning‑fast reverse network tunnel with DPI‑evasion transports.**

LeechTunnel (`leech`) is a high‑performance reverse tunnel for linking a server
inside a restricted network to a server abroad. It carries your traffic over a
range of transports — plain TCP up to fully TLS/WebSocket‑disguised channels —
so it keeps flowing where ordinary connections get throttled or blocked. Traffic
is paced with **BBR** congestion control, which holds throughput on lossy /
high‑latency links where the default algorithm collapses.

Distributed as a single self‑contained, **obfuscated** binary plus an
interactive configurator — no dependencies, no build step.

---

## 🚀 Install (one line)

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/ALIZA4004/LeechTunnel/main/install.sh)
```

This downloads the core + configurator into `/root/leech`, registers a `leech`
command, and opens the menu. Run it on **both** servers (inside and abroad).

## 📦 Manual install

```bash
git clone https://github.com/ALIZA4004/LeechTunnel.git
cd LeechTunnel
bash leech.sh   # auto-downloads the obfuscated core (latest release) into /root/leech
```

The obfuscated core binary ships as the **[latest release](https://github.com/ALIZA4004/LeechTunnel/releases/latest)**
asset — not in the file tree — so `leech.sh` and `install.sh` fetch it from
`https://github.com/ALIZA4004/LeechTunnel/releases/latest/download/leech` automatically.
To place it by hand:

```bash
mkdir -p /root/leech
curl -fL -o /root/leech/leech https://github.com/ALIZA4004/LeechTunnel/releases/latest/download/leech
chmod +x /root/leech/leech
```

---

## 🛠 Usage

Running `leech.sh` (or the `leech` command) opens a menu:

```
 1. Configure a new tunnel
 2. Tunnel management
 3. Check tunnel status
 4. Web panel (GUI)
 5. Update LEECH Core
 6. Update script
 7. Remove LEECH Core
 0. Exit
```

Choose **1** to build a tunnel. On the abroad server pick **server**, on the
inside server pick **client** and point it at the abroad server's IP + port.
Each tunnel is installed as a `systemd` service (`leech-<type><port>.service`)
that starts on boot and auto‑reconnects if the link drops.

Prefer the reverse topology (ports live on the server side) — it's the default
the configurator sets up.

---

## 🖥️ Web panel (GUI)

LeechTunnel ships a self‑hosted **web control panel** — a single static binary
(`leech-panel`, zero dependencies) with **live per‑tunnel monitoring**.

1. On one server (the hub) run `leech` → **4. Web panel** → **Install panel**.
   It asks for a **port** and an **admin password**, serves the panel on that
   port, and prints the panel's SSH key.
2. On every other server run **4 → Connect to panel** and paste that key to
   enroll it as a node.
3. Keep it current with **4 → Update panel** (verified hot‑swap, auto‑rollback).

Three tabs: **Nodes** (live CPU / RAM / traffic per server), **Create tunnel**,
and **Tunnels** (a live topology graph + per‑tunnel throughput / CPU / RAM
charts). One relay can fan out to many exits, and many exits to one relay.
Bilingual (EN / فارسی, RTL).

The create form is the configurator, in the browser: pick a transport from the
card grid and every parameter that transport supports appears — grouped into
collapsible sections, each field with a **ⓘ** explaining what it does, and
sub‑branches that unfold as you go (TUN → encapsulation → the IPX raw‑packet
engine → its profile and encryption; TCP → accept‑UDP → the UDP ring settings).
Fields are tagged with the end they apply to, layer‑3 addressing is derived per
end automatically, and a live preview shows the exact config both servers will
get before you press create.

Access it at `http://<hub-ip>:<port>`. Control between the hub and nodes is over
SSH (key‑based, command allow‑list); live metrics stream to the browser via SSE.

---

## ✨ Features

- **11 transports** — pick per link:
  `tcp`, `tcpmux`, `ws`, `wss`, `wsmux`, `wssmux`, `xtcpmux`, `xwsmux`,
  `anytls`, `kcp` (UDP + FEC), and `tun` (layer‑3).
- **Acceleration (default ON)** — BBR congestion control; multiplies throughput
  on real long‑distance / lossy links, neutral on clean ones.
- **DPI evasion** — real‑browser uTLS fingerprints on the TLS transports,
  domain‑fronting `Host`, secret HMAC‑derived WebSocket paths, a configurable
  decoy website on unknown paths, SNI rotation, and optional Noise obfuscation
  on the raw‑TCP carriers.
- **Multiplexing** — the `*mux` transports carry many streams over one
  connection (smux), reducing connection churn.
- **Resilient** — heartbeat health‑checks + exponential‑backoff reconnect on
  every transport.

---

## 📋 Requirements

- Linux, `x86_64`, root access.
- Two servers (one inside the restricted network, one abroad) that can reach
  each other on the tunnel port.

## 🔄 Update / Uninstall

- **Update the core:** menu option **5** (pulls the latest binary from this repo).
- **Update the configurator:** menu option **6**.
- **Update the panel:** menu **4 → 4** (downloads, verifies, hot‑swaps the binary,
  and rolls back automatically if the new build fails to start).
- **Remove:** menu option **7**, or `rm -rf /root/leech /usr/local/bin/leech`
  and `systemctl disable --now leech-*.service`.

---

## 🇮🇷 توضیح کوتاه

**LeechTunnel** یک تونلِ معکوسِ پُرسرعت است برای اتصالِ یک سرورِ داخل به یک سرورِ
خارج، تا ترافیک از مسیرهایی که مسدود/کند می‌شوند عبور کند. یازده ترنسپورت
(از TCP ساده تا کاملاً پنهان در TLS/WebSocket)، شتاب‌دهیِ **BBR**، و مجموعه‌ای از
تکنیک‌های ضدِ DPI دارد. به‌صورتِ یک باینریِ مبهم‌سازی‌شده + یک اسکریپتِ کانفیگِ
تعاملی توزیع می‌شود.

**نصبِ یک‌خطی** (روی هر دو سرور، به‌عنوان root):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ALIZA4004/LeechTunnel/main/install.sh)
```

سپس گزینهٔ **۱** را برای ساختِ تانل بزن: روی سرورِ خارج «server» و روی سرورِ داخل
«client» (با IP و پورتِ سرورِ خارج). هر تانل به‌صورتِ سرویسِ systemd نصب می‌شود که
با هر قطعی خودکار وصل می‌شود.

**پنلِ گرافیکی:** گزینهٔ **۴** → «Install panel» روی یکی از سرورها (هاب) پنل را
با پورت و رمزِ دلخواه بالا می‌آورد و کلیدِ SSH‌اش را چاپ می‌کند؛ روی بقیهٔ سرورها
گزینهٔ **۴ → Connect to panel** همان کلید را می‌گیرد و آن سرور را به‌عنوان نود
اضافه می‌کند. پنل سه سربرگ دارد: نودها، ساختِ تانل، و تانل‌ها (نمودارِ توپولوژی و
مانیتورینگِ زندهٔ ترافیک/رم/پردازندهٔ هر تانل). یک ایران به چند خارج و چند خارج به
یک ایران هر دو پشتیبانی می‌شود، و فرمِ ساخت دقیقاً همان پارامترهای اسکریپتِ
کانفیگ را — با توضیحِ هر گزینه و زیرشاخه‌هایش — در مرورگر می‌دهد.
