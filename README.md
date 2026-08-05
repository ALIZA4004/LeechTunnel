# LeechTunnel

Fast reverse tunnel with DPI‑evasion transports — a single obfuscated binary + an
interactive configurator + a web control panel. No dependencies, no build step.

![LEECH web panel](docs/panel.png)

---

## Install (one line)

Run on **both** servers (inside + abroad), as **root**:

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/ALIZA4004/LeechTunnel/main/install.sh)
```

Downloads the core + configurator into `/root/leech`, registers a `leech` command,
and opens the menu.

### Manual install

```bash
mkdir -p /root/leech
curl -fL   -o /root/leech/leech    https://github.com/ALIZA4004/LeechTunnel/releases/latest/download/leech
curl -fsSL -o /root/leech/leech.sh https://raw.githubusercontent.com/ALIZA4004/LeechTunnel/main/leech.sh
chmod +x /root/leech/leech
cd /root/leech && bash leech.sh
```

## Menu

```
 1  Configure a new tunnel     (abroad = server · inside = client → point at abroad IP:port)
 2  Tunnel management
 3  Tunnel status
 4  Web panel   (install / connect / update)
 5  Update core     6  Update script     7  Remove
```

Each tunnel installs as a `systemd` service that starts on boot and auto‑reconnects.

## Web panel

`leech` → **4 → Install panel** — asks a **port** + **admin password**, prints an SSH key.
On every other server: **4 → Connect** and paste that key to enroll it as a node.
Live per‑tunnel monitoring + the topology graph shown above. EN / فارسی.

---

## نصب (فارسی)

روی **هر دو سرور** (داخل و خارج)، به‌عنوان **root**:

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/ALIZA4004/LeechTunnel/main/install.sh)
```

سپس دستور `leech` را بزن:

- گزینهٔ **۱** → ساختِ تانل (روی سرورِ **خارج** حالتِ «server»، روی سرورِ **داخل** حالتِ
  «client» و آدرس/پورتِ سرورِ خارج را بده). هر تانل به‌صورتِ سرویسِ `systemd` نصب می‌شود و
  با هر قطعی خودکار وصل می‌شود.
- **پنلِ گرافیکی:** گزینهٔ **۴ → Install panel** روی یک سرور (هاب) با پورت و رمزِ دلخواه؛
  روی بقیه **۴ → Connect** و همان کلید را بچسبان. مانیتورینگِ زندهٔ هر تانل + نمودارِ توپولوژی
  (تصویرِ بالا).
- بروزرسانی: **۵** هسته · **۶** اسکریپت · **۴ → Update panel** برای پنل.
