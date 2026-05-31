# Run this lab on Oracle Cloud (OCI Always Free)

No local Docker, or not enough RAM on your laptop? You can run the whole lab on a **free** cloud VM.
Oracle's **OCI Always Free** tier includes an **Arm Ampere A1** allowance of **4 OCPUs + 24 GB RAM** —
far more than this lab needs — at no cost, on a *personal* account.

> Always Free really is free, but create a **personal** account (your own email/card for identity
> verification — Always Free resources aren't charged). Don't run this in an employer's tenancy.

## 1. Create the VM

In the OCI Console → **Compute → Instances → Create instance**:

- **Shape:** `VM.Standard.A1.Flex` (Ampere Arm). Set **OCPUs = 2, Memory = 12 GB** (well within the
  Always Free 4-OCPU / 24-GB allowance, and plenty for the lab).
- **Image:** Oracle Linux 9 (or Ubuntu 22.04 — commands below are for Oracle Linux 9).
- **Networking:** the default VCN is fine. You do **not** need to open any ports: the drills run
  *inside* the container via `docker exec`, so nothing has to be exposed to the internet.
- Add your SSH public key, then **Create**.

> Always Free Ampere capacity varies by region — if you get an "out of capacity" error, try again
> later or pick a different home region when you sign up.

## 2. Install Docker

SSH in (`ssh opc@<public-ip>`), then:

```bash
sudo dnf install -y dnf-utils
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"     # then log out and back in so the group applies
```

Verify: `docker version && docker compose version`.

## 3. Run the lab

```bash
sudo dnf install -y git
git clone https://github.com/pyaroslav/oracle-labs.git
cd oracle-labs/ha
./run.sh up
./run.sh all
```

That's it — same three drills, same expected output as the local lab (see [README](README.md)).

## 4. Tear down

When you're done, **terminate the instance** in the OCI Console (Compute → Instances → … → Terminate)
to keep your tenancy clean. The lab's data lives in a Docker volume on the VM, so terminating the VM
removes everything.

## Optional: connect a SQL client from your laptop

Only if you want to (not needed for the drills): open port **1521** in the VCN's **security list**
(ingress from *your* IP only), start the lab with a published port — `LAB_PORT=1521 ./run.sh up` — and
connect to `<public-ip>:1521/FREEPDB1`. Treat this as a disposable lab; never expose it broadly.
