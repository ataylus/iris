# Guests

## Adding someone

A guest needs two things. The first is done once per person, in Tailscale. The second is done in
the Iris window.

### 1. Share this laptop with them in Tailscale

1. Go to https://login.tailscale.com/admin/machines
2. Find this laptop, open the `...` menu on its row, and choose **Share**.
3. Copy the invite link and send it to them.

They accept it signed in to their own Tailscale account. They then see this one laptop and nothing
else on your network. Do not invite them as a member of your tailnet; that gives access to
everything on it.

### 2. Add them in Iris

1. Type their name in the box under **Guests** and click **Add**.
   Names use letters, numbers, `-` and `_`, with no spaces.
2. Click **Copy link** next to their name and paste it to them.

The invite is a ready-made message containing their personal link. Clicking it signs them in.

## What the guest does

Send them this the first time. On Windows, in PowerShell run as administrator:

```powershell
winget install --id Tailscale.Tailscale -e --accept-source-agreements --accept-package-agreements
& "C:\Program Files\Tailscale\tailscale.exe" up
```

1. The second command opens a sign-in page. They sign in (a Google account is fine).
2. They open your Tailscale share link and accept it with the same account.
3. They click the Iris invite link.

After the first time it is only step 3, as long as Tailscale is running on their computer.
If `winget` is not recognised, they install from https://tailscale.com/download instead.

## Removing someone

Click the `x` next to their name. Their account is deleted, their link stops working, and if they
are watching they are disconnected on the spot.

To also remove their network access, delete the share on the laptop's page in the Tailscale
admin console.

## Good to know

- **One device per person.** A second login on the same account is refused while the first is connected.
- **Links only work while Iris is running.** Start Iris before sending a link.
- **After switching Saved/Fresh**, everyone refreshes their page to reconnect.
- **To change a password**, remove the guest and add them again, then send the new invite.
  Your own password is in `people.json`; edit it there while Iris is closed.

## Limit what shared users can reach (applied)

Tailscale's default policy lets someone you share the laptop with try any open port on it,
including Windows file sharing. This tailnet's policy restricts shared users to the two ports Iris
uses. If it is ever reset, open the Tailscale admin console, go to **Access controls**, then
**JSON editor**, and use this as the whole file. Replace `100.x.y.z` with this laptop's Tailscale
address (shown in `.env`):

```json
{
    "grants": [
        {"src": ["autogroup:member"], "dst": ["*"], "ip": ["*"]},
        {"src": ["autogroup:shared"], "dst": ["100.x.y.z"], "ip": ["443", "59000"]},
    ],
}
```

This also leaves out Funnel and Tailscale SSH, which Iris does not need. To check that it applied:

```powershell
(& "C:\Program Files\Tailscale\tailscale.exe" debug netmap | ConvertFrom-Json).PacketFilter
```

Shared users' addresses should list only `443` and `59000` on this laptop.
