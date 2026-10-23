#!/system/bin/sh
# jg-redroid: persistent root daemon started natively via init.rc (capabilities NET_ADMIN,
# NOT Magisk/su). Runs forever, self-healing: swaps the real eth0 into the "wlan0" slot once
# the wifi HAL patch signals it's safe to (see TRIGGER below), and keeps re-asserting the IP/
# route if anything (Android's own WiFi disconnect handling flushes IpClient's provisioning on
# CMD_UNWANTED_NETWORK teardown) removes them - decoupled entirely from WiFi's connection state
# from that point on.
#
# Replaces an earlier design that called `su -c` from system_server on every fake-wifi
# connect/reconnect: that reproducibly broke gralloc HAL resolution (`gralloc-mapper is
# missing`, screencap/scrcpy dying) - traced to Magisk's own mount-namespace manipulation on
# su escalation leaking into system_server's namespace. Running natively as root via init.rc
# avoids Magisk entirely for this.
#
# Captured IP/gateway are written to a small file so the wifi HAL patch
# (SupplicantStaIfaceHalHidlImplExt) can read them with plain file I/O - no exec, no su -
# to build the StaticIpConfiguration it hands to IpClient.

NETINFO=/data/local/tmp/.jg-netinfo
# jg-redroid: gates the (one-time) rename. wificond only creates its own "wlan0" from the
# hwsim phy once WiFi is actually enabled - if this daemon renamed eth0 to "wlan0" any
# earlier (e.g. right after the host-side hwsim netns move, before the app/user ever touched
# WiFi), it would steal the name out from under wificond's own setup and wifi would silently
# fail to enable. So the rename only proceeds once SupplicantStaIfaceHalHidlImplExt.
# connectToNetwork() has actually fired and dropped this trigger (plain Java file write - no
# exec, no su, can't reintroduce the gralloc problem).
TRIGGER=/data/system/.jg-swap-trigger
# jg-redroid: /data/system survives container restarts (it's in the persistent /data
# volume), but the rename/interface state does NOT - every restart gets a brand new netns
# with eth0 intact and no swap done yet. A trigger left over from a previous boot would make
# this daemon rename eth0 on its very first tick, before wificond has re-created its own
# wlan0 on the (also brand new) hwsim phy - recreating the exact race the trigger exists to
# prevent. So any stale trigger from a prior boot must be cleared before the loop starts;
# Java will drop a fresh one the next time a real connect attempt happens during this boot.
rm -f "$TRIGGER" 2>/dev/null
IP=""
GW="172.17.0.1"

while true; do
    if [ -e "$TRIGGER" ] && [ -e /sys/class/net/eth0 ] && [ -e /sys/class/net/wlan0 ] && [ ! -e /sys/class/net/wlan0_fake ]; then
        NEWIP=$(ip -4 addr show dev eth0 2>/dev/null | awk '/inet /{print $2; exit}')
        NEWGW=$(ip route show dev eth0 2>/dev/null | awk '/^default/{print $3; exit}')
        [ -n "$NEWIP" ] && IP="$NEWIP"
        [ -n "$NEWGW" ] && GW="$NEWGW"
        ip link set wlan0 name wlan0_fake 2>/dev/null
        ip link set eth0 name wlan0 2>/dev/null
        ip link set wlan0 up 2>/dev/null
    fi

    if [ -e /sys/class/net/wlan0_fake ] && [ -n "$IP" ]; then
        # jg-redroid: el chequeo original solo miraba si wlan0 tenia ALGUNA direccion inet,
        # no si era la CORRECTA - si quedaba una direccion vieja/de otra instancia (ej. tras
        # un docker recreate que le asigno una IP de bridge distinta a este contenedor), este
        # check pasaba igual y la IP correcta nunca se agregaba. El host quedaba haciendo ARP
        # para una IP que el contenedor nunca respondia, sin resolver jamas (no era timing,
        # era una direccion mal puesta). Reproducido y confirmado 2026-07-28 en
        # pvz2-fogelmajg. Fix: comparar contra la IP capturada puntualmente, no "cualquiera".
        ip addr show wlan0 2>/dev/null | grep -qF "inet $IP" || {
            ip addr flush dev wlan0 2>/dev/null
            ip addr add "$IP" dev wlan0 2>/dev/null
        }
        ip rule show 2>/dev/null | grep -q 'lookup main' || ip rule add priority 25000 lookup main 2>/dev/null
        ip route show 2>/dev/null | grep -q '^default' || ip route add default via "$GW" dev wlan0 2>/dev/null
        # jg-redroid: this shell's default umask leaves the file 0600 (root-only) - system_server
        # (uid 1000, a different user) then fails to read it with AccessDeniedException, silently
        # falling back to a real (nonexistent) DHCP server and disconnecting after ~18s. Must be
        # world-readable.
        echo "$IP $GW" > "$NETINFO.tmp" 2>/dev/null && chmod 644 "$NETINFO.tmp" 2>/dev/null && mv "$NETINFO.tmp" "$NETINFO" 2>/dev/null
    fi

    sleep 5
done
