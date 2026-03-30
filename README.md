# piyano

Turn a Raspberry Pi 5 into a headless, boot-to-play piano using [Pianoteq](https://www.modartt.com/pianoteq) and a [Raspberry Pi DAC+](https://www.raspberrypi.com/products/dac-plus/). Plug in a USB MIDI keyboard, power on, and play — no monitor, no desktop, no fuss.

## Hardware

| Component | Notes |
|---|---|
| Raspberry Pi 5 (2 GB+) | 2 GB is plenty for headless Pianoteq |
| [Raspberry Pi DAC+](https://www.raspberrypi.com/products/dac-plus/) | I2S HAT using PCM5122 (formerly IQaudio DAC+) — no special drivers beyond a device tree overlay |
| USB MIDI keyboard | Any class-compliant controller; auto-detected |
| microSD card (16 GB+) | For Raspberry Pi OS |
| USB-C power supply | Official Pi 5 PSU recommended (5V / 5A) |
| Ethernet or wifi | Needed for SSH and first-boot Pianoteq activation |

## Quick Start

### 1. Flash the OS

Write **Raspberry Pi OS Lite 64-bit** to your SD card using [Raspberry Pi Imager](https://www.raspberrypi.com/software/). Tested on Debian Trixie; Bookworm should also work.

In the imager settings:

- In "Device" choose your Raspberry Pi model (Raspberry Pi 5)
- In "OS" choose "Raspberry Pi OS (Other)", then "Raspberry Pi OS Lite (64-bit)
- Set your hostname (e.g. `piyano`)
- Set your username and password (we use `pi` for the username in these instructions)
- Enter the Wifi connection details if you don't plan to use Ethernet
- Enable SSH (password or key)

Write the image. When it has finished, put the SD card into your Raspberry pi, turn it on, and wait for it to boot.

### 2. Get this repo onto the Pi

```bash
ssh pi@piyano.local
sudo apt-get install -y git
git clone https://github.com/cogat/piyano.git
cd piyano
mkdir -p ~/pianoteq-pkg
# optional command to make pulls
git config pull.rebase true
```

### 3. Get Pianoteq onto the Pi

You need a Pianoteq Linux archive. Download the **Linux** package from [your Modartt account](https://www.modartt.com/user_area) (or grab the [free trial](https://www.modartt.com/try)), then copy it to the Pi:

```bash
# From your computer:
scp ~/Downloads/pianoteq_linux_v*.7z pi@piyano.local:~/pianoteq-pkg/
```

Then run setup:

```bash
# On the Pi:
sudo ./setup.sh
```

Or point directly at the archive:

```bash
sudo ./setup.sh --pianoteq-archive ~/Downloads/pianoteq_linux_v843.7z
```

Supported formats: `.7z`, `.tar.xz`, `.tar.gz`, `.zip`

### 4. Reboot

```bash
sudo reboot
```

### 5. Play

Plug in your MIDI keyboard. Pianoteq starts automatically and begins listening for MIDI input. Sound comes out of the Raspberry Pi DAC+.

On first boot with internet, Pianoteq will need to be activated. See [Activation](#first-boot-and-activation) below.

## First Boot and Activation

Pianoteq requires a one-time online activation tied to your licence serial number. The first boot **must** have internet access.

To activate, SSH in and run:

```bash
sudo systemctl stop pianoteq
sudo -u pianoteq /opt/pianoteq/Pianoteq --activate <your-serial>
sudo systemctl start pianoteq
```

The Modartt activation server can be flaky — if it fails with a connection error, just run the `--activate` command again. It usually works within two or three attempts.

After activation, the Pi no longer needs internet to function.

If you're using the trial, no activation is needed — it works immediately (with limitations).

Check Pianoteq is running by visiting `http://piyano.local:8081/` and you should see a welcome message.

## What the Script Does

`setup.sh` makes these changes to your system (all idempotent — safe to re-run):

| Category | Change |
|---|---|
| **Packages** | Installs `alsa-utils`, `curl`, `p7zip-full`, `xz-utils` |
| **Pianoteq** | Extracts the `arm-64bit` binary to `/opt/pianoteq/Pianoteq` |
| **GPU memory** | Sets `gpu_mem=16` in config.txt (headless, no GPU needed) |
| **DAC** | Adds `dtoverlay=iqaudio-dacplus` (auto-detects HiFiBerry or RPi DAC+), disables onboard audio |
| **Bluetooth** | Disabled (`dtoverlay=disable-bt` + systemd) |
| **CPU governor** | Set to `performance` (no clock scaling) |
| **PulseAudio/PipeWire** | Removed — direct ALSA hardware access only |
| **ALSA** | Installs `/etc/asound.conf` targeting the DAC at 48 kHz |
| **User** | Creates system user `pianoteq` with home `/opt/pianoteq` |
| **systemd** | Installs and enables `pianoteq.service` (headless + JSON-RPC on port 8081) |
| **Wifi** | Left alone by default (use `--disable-wifi` to turn off) |

### setup.sh flags
```
--pianoteq-archive PATH     Use a specific archive file
--with-tweaks               Apply CPU isolation (see below)
--disable-wifi              Disable wifi radio
-h, --help                  Show help
```

## Changing Sounds and Presets

### Listing available presets

**From the Pi via SSH:**

```bash
sudo -u pianoteq /opt/pianoteq/Pianoteq --list-presets
```

**Via JSON-RPC (from any device on your network):**

```bash
curl -s http://piyano.local:8081/jsonrpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getListOfPresets"}' | python3 -m json.tool
```

### Checking which instruments are activated

```bash
curl -s http://piyano.local:8081/jsonrpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getActivationInfo"}' | python3 -m json.tool
```

### Switching presets

**Via JSON-RPC:**

```bash
# Load a specific preset
curl -s http://piyano.local:8081/jsonrpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"loadPreset","params":{"name":"D4 Classical","bank":"","preset_type":"full"}}'

# Cycle through presets
curl -s http://piyano.local:8081/jsonrpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"nextPreset"}'
```

**Set a default preset on boot** by editing the systemd service:

```bash
sudo systemctl edit pianoteq.service
```

Add an override:

```ini
[Service]
ExecStart=
ExecStart=/opt/pianoteq/Pianoteq --headless --multicore max --serve 0.0.0.0:8081 --preset "D4 Classical"
```

### Switching presets via MIDI controller

Pianoteq supports MIDI Program Change messages for preset switching. You can configure this through a MIDI mapping.

**Using a saved mapping:**

If you have a Pianoteq MIDI mapping configured (e.g. from a desktop install), add `--midimapping "My Mapping"` to the systemd ExecStart line as shown above.

### Using the web remote control

Pianoteq's JSON-RPC server doubles as a simple web interface. Open `http://piyano.local:8081/` in your browser to see the interactive API reference.

For a full-featured phone/tablet control panel, see [ptq-client-webapp](https://github.com/robert-rc2i/ptq-client-webapp). It connects to the same JSON-RPC endpoint.

### Transferring presets to the Pi

User presets are `.fxp` files. Copy them into the presets directory:

```bash
scp "My Piano.fxp" pi@piyano.local:/tmp/
ssh pi@piyano.local
sudo mkdir -p /opt/pianoteq/.local/share/Modartt/Pianoteq/Presets/My\ Presets/
sudo cp /tmp/My\ Piano.fxp /opt/pianoteq/.local/share/Modartt/Pianoteq/Presets/My\ Presets/
sudo chown -R pianoteq:pianoteq /opt/pianoteq/.local
sudo systemctl restart pianoteq
```

### Installing instrument add-on packs

Instrument packs are `.ptq` files. Copy them to the Addons directory:

```bash
scp "My Instrument.ptq" pi@piyano.local:/tmp/
ssh pi@piyano.local
sudo mkdir -p /opt/pianoteq/.local/share/Modartt/Pianoteq/Addons/
sudo cp /tmp/My\ Instrument.ptq /opt/pianoteq/.local/share/Modartt/Pianoteq/Addons/
sudo chown -R pianoteq:pianoteq /opt/pianoteq/.local
sudo systemctl restart pianoteq
```

### Pianoteq JSON-RPC reference

Key methods available at `http://piyano.local:8081/jsonrpc`:

| Method | Description |
|---|---|
| `list` | List all available RPC methods |
| `getListOfPresets` | All presets with bank/instrument metadata |
| `getActivationInfo` | Which instrument packs are licensed vs demo |
| `getInfo` | Current state (active preset, instrument) |
| `loadPreset(name, bank)` | Switch to a specific preset |
| `nextPreset` / `prevPreset` | Cycle presets |
| `nextInstrument` / `prevInstrument` | Cycle instruments |
| `getParameters` / `setParameters` | Read/write synth parameters |
| `midiSend(bytes)` | Inject MIDI events programmatically |

The full interactive reference is served by Pianoteq at `http://piyano.local:8081/` when the service is running.

## Configuration Reference

### Audio settings

Edit `/etc/asound.conf` to change ALSA parameters. The defaults are:

- Sample rate: 48 kHz
- Card: auto-detected HiFiBerry (falls back to card 0)

### Changing the JSON-RPC port

Edit the systemd service:

```bash
sudo systemctl edit pianoteq.service
```

Replace `8081` with your preferred port in the ExecStart override.

### Service management

```bash
sudo systemctl status pianoteq    # Check status
sudo systemctl restart pianoteq   # Restart
sudo systemctl stop pianoteq      # Stop
journalctl -u pianoteq -f         # Follow logs
```

## Optional: CPU Isolation Tweaks

For the lowest possible latency, you can isolate CPU cores 1-3 from the Linux scheduler so Pianoteq has near-exclusive access to them.

```bash
sudo ./setup.sh --with-tweaks
```

Or run the tweak script directly:

```bash
sudo ./tweaks/isolcpus.sh
```

This does two things:

1. Adds `isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3` to `/boot/firmware/cmdline.txt`
2. Installs a oneshot service that pins USB and I2S IRQs to the isolated cores

**This is experimental.** To revert:

1. Edit `/boot/firmware/cmdline.txt` and remove the `isolcpus`, `nohz_full`, and `rcu_nocbs` parameters
2. `sudo systemctl disable --now irq-affinity.service`
3. Reboot

## Troubleshooting

### Locale warning when SSHing in

If you see `warning: setlocale: LC_CTYPE: cannot change locale (en_US.UTF-8)` when SSHing into the Pi, your SSH client is forwarding a locale that isn't generated on the Pi. The setup script fixes this automatically, but if you haven't run it yet:

```bash
sudo locale-gen en_US.UTF-8
sudo update-locale LANG=en_US.UTF-8
```

### No sound

- **DAC not detected:** Check `aplay -l` for a DAC card. Verify the correct overlay is in config.txt (`dtoverlay=iqaudio-dacplus` for Raspberry Pi DAC+, or `dtoverlay=hifiberry-dacplus` for HiFiBerry) and `dtparam=audio=off` disables onboard audio. Reboot after changes.
- **Wrong card number:** Run `aplay -l` and compare with `/etc/asound.conf`. Re-run `setup.sh` to auto-detect, or edit the card number manually.
- **ALSA device busy:** Check nothing else is using the audio device: `fuser -v /dev/snd/*`

### MIDI keyboard not detected

- Check `aconnect -l` to list MIDI devices. Your keyboard should appear as a client.
- Try a different USB port or cable.
- Check `dmesg | grep -i midi` for kernel messages.

### High latency

- Verify CPU governor: `cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` should say `performance`.
- Consider the `--with-tweaks` CPU isolation option.
- Check buffer size in Pianoteq — lower values reduce latency but increase CPU load.

### Pianoteq won't start

- Check logs: `journalctl -u pianoteq -e`
- Verify the binary exists: `ls -la /opt/pianoteq/Pianoteq`
- Test manually: `sudo -u pianoteq /opt/pianoteq/Pianoteq --headless`

### Activation problems

- First boot requires internet. Check connectivity: `ping -c 1 modartt.com`
- For offline activation, see [Modartt's activation help](https://www.modartt.com/activation_help).

### JSON-RPC not responding

- Verify the service is running: `systemctl status pianoteq`
- Check the port is listening: `ss -tlnp | grep 8081`
- From another machine, ensure you can reach the Pi on port 8081 (no firewall blocking).

## Uninstalling

To reverse everything piyano did:

```bash
# Stop and remove the service
sudo systemctl stop pianoteq
sudo systemctl disable pianoteq
sudo rm /etc/systemd/system/pianoteq.service
sudo systemctl daemon-reload

# Remove the pianoteq user and install directory
sudo userdel pianoteq
sudo rm -rf /opt/pianoteq

# Remove ALSA config
sudo rm /etc/asound.conf

# Restore config.txt (remove these lines):
#   gpu_mem=16
#   dtparam=audio=off
#   dtoverlay=iqaudio-dacplus   (or hifiberry-dacplus)
#   dtoverlay=disable-bt
sudo nano /boot/firmware/config.txt

# Re-enable bluetooth
sudo systemctl enable bluetooth

# If CPU tweaks were applied:
sudo systemctl disable --now irq-affinity.service
sudo rm /etc/systemd/system/irq-affinity.service
sudo rm /usr/local/bin/piyano-irq-affinity.sh
# Edit /boot/firmware/cmdline.txt to remove isolcpus/nohz_full/rcu_nocbs params

sudo reboot
```

## Contributing / Developer Setup

### Prerequisites

- [mise](https://mise.jdx.dev) — manages shellcheck and shfmt automatically

### Setup

```bash
git clone https://github.com/cogat/piyano.git
cd piyano
mise install    # installs shellcheck + shfmt
```

### Development workflow

```bash
mise run lint    # check scripts with shellcheck
mise run fmt     # auto-format scripts with shfmt
mise run check   # CI-style check (format diff + lint) — run before committing
```

### Style guide

- `#!/usr/bin/env bash` + `set -euo pipefail`
- 2-space indentation
- Idempotent operations (grep before append, stat before create)
- Output via `info()`, `warn()`, `error()`, `success()` helpers
- No comments that merely narrate what the code does

### Testing on a Pi

```bash
rsync -avz --exclude='.git' . pi@piyano.local:~/piyano/
ssh pi@piyano.local 'cd piyano && sudo ./setup.sh'
```

### Project protocols

See [AGENTS.md](AGENTS.md) for AI-assisted development conventions.

## Licence

This project is licensed under the [MIT License](LICENSE).

**Pianoteq is proprietary software owned by [Modartt](https://www.modartt.com/).** It is not included in or distributed by this project.

## Acknowledgements

- [Modartt](https://www.modartt.com/) — Pianoteq
- [Pianoberry](https://github.com/elektrofon/pianoberry) — inspiration and prior art
- [pianoteq-pi](https://github.com/youfou/pianoteq-pi) — Pi setup reference
- [ptq-client-webapp](https://github.com/robert-rc2i/ptq-client-webapp) — web remote for Pianoteq
- [Raspberry Pi DAC+](https://www.raspberrypi.com/products/dac-plus/) — audio HAT hardware (formerly IQaudio)
