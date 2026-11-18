#!/usr/bin/env python3
"""Regenerates Sources/FlightDeckCore/OUIVendors.swift, the compact MAC-prefix -> vendor table the Network map uses.

Input is Wireshark's `manuf` file (derived from the IEEE MA-L registry), downloaded by hand:

    curl -sSL -o /tmp/manuf https://www.wireshark.org/download/automated/data/manuf
    python3 -I scripts/gen-oui.py /tmp/manuf > Sources/FlightDeckCore/OUIVendors.swift

Only 24-bit (MA-L) blocks of the vendors listed below are kept: those are the brands a home or office network
plausibly contains, and keeping the list curated keeps the table small (tens of KB instead of the full registry's
~40,000 entries). Each vendor's registry names are matched with a regex, so "Samsung Electronics Co.,Ltd" and
"Samsung Electro-Mechanics" both become "Samsung". Vendors not listed simply aren't recognised, and the app shows
"unknown vendor" for them rather than guessing.
"""
import re
import sys

# (display name, regex matched against the registry's full organisation name). First match wins, so more specific
# entries (Cisco Meraki, Linksys) come before broader ones (Cisco).
VENDORS = [
    ("Apple", r"^Apple, Inc"),
    ("Samsung", r"^Samsung Electr"),
    ("Google", r"^Google"),
    ("Nest", r"^Nest Labs"),
    ("Amazon", r"^Amazon"),
    ("Ring", r"^Ring LLC"),
    ("Microsoft", r"^Microsoft"),
    ("Sony", r"^Sony|^SONY"),
    ("LG", r"^LG Electronics|^Lg Electronics|^LG Innotek"),
    ("Intel", r"^Intel Corporat"),
    ("Dell", r"^Dell Inc|^Dell EMC"),
    ("HP", r"^Hewlett Packard$|^HP Inc"),
    ("HPE", r"^Hewlett Packard Enterprise"),
    ("Lenovo", r"^Lenovo"),
    ("Motorola", r"^Motorola Mobility"),
    ("ASUS", r"^ASUSTek"),
    ("Acer", r"^Acer "),
    ("Huawei", r"^Huawei Technologies|^Huawei Device"),
    ("Honor", r"^Honor Device"),
    ("Xiaomi", r"Xiaomi"),
    ("OPPO", r"^Guangdong Oppo"),
    ("OnePlus", r"^OnePlus"),
    ("vivo", r"^vivo Mobile"),
    ("Nokia", r"^Nokia$|^Nokia Corporation"),
    ("HTC", r"^HTC Corporation"),
    ("Nintendo", r"^Nintendo"),
    ("Valve", r"^Valve Corporation"),
    ("Roku", r"^Roku"),
    ("Vizio", r"^Vizio"),
    ("Hisense", r"Hisense"),
    ("TCL", r"^TCL |^Tcl "),
    ("Panasonic", r"^Panasonic"),
    ("Sharp", r"^SHARP Corporation|^Sharp Corporation"),
    ("Toshiba", r"^Toshiba"),
    ("Sonos", r"^Sonos"),
    ("Bose", r"^Bose Corporation"),
    ("Yamaha", r"^Yamaha Corporation"),
    ("Denon / Marantz", r"^D&M Holdings|^Sound United"),
    ("Philips Hue", r"^Philips Lighting|^Signify"),
    ("ecobee", r"^ecobee"),
    ("Aqara", r"^Lumi United"),
    ("Shelly", r"^Shelly"),
    ("IKEA", r"^IKEA"),
    ("Tuya", r"^Tuya"),
    ("Espressif", r"^Espressif"),
    ("Belkin", r"^Belkin"),
    ("Wyze", r"^Wyze"),
    ("Arlo", r"^Arlo Technology"),
    ("Chamberlain", r"^The Chamberlain Group"),
    ("iRobot", r"^iRobot"),
    ("Dyson", r"^Dyson"),
    ("Withings", r"^Withings"),
    ("Netatmo", r"^Netatmo"),
    ("Hikvision", r"Hikvision"),
    ("EZVIZ", r"Ezviz"),
    ("Dahua", r"Dahua"),
    ("Reolink", r"^Reolink"),
    ("Tesla", r"^Tesla"),
    ("Peloton", r"^Peloton"),
    ("Garmin", r"^Garmin"),
    ("Fitbit", r"^Fitbit"),
    ("Logitech", r"Logitech"),
    ("Raspberry Pi", r"^Raspberry Pi"),
    ("Synology", r"^Synology"),
    ("QNAP", r"^QNAP"),
    ("Western Digital", r"^Western Digital"),
    ("Seagate", r"^Seagate"),
    ("Brother", r"^Brother [Ii]ndustries"),
    ("Canon", r"^Canon Inc"),
    ("Epson", r"^Seiko Epson"),
    ("Xerox", r"^Xerox Corporation"),
    ("Lexmark", r"^Lexmark"),
    ("Ricoh", r"^Ricoh Company"),
    ("Kyocera", r"^Kyocera|^KYOCERA"),
    ("Cisco Meraki", r"^Cisco Meraki"),
    ("Linksys", r"Linksys"),
    ("Cisco", r"^Cisco Systems"),
    ("Ubiquiti", r"^Ubiquiti"),
    ("eero", r"^eero"),
    ("Netgear", r"^Netgear"),
    ("TP-Link", r"^Tp-Link|^TP-Link"),
    ("D-Link", r"^D-Link"),
    ("Zyxel", r"^Zyxel"),
    ("AVM (FRITZ!)", r"^AVM Audiovisuelles|^AVM GmbH"),
    ("MikroTik", r"^Routerboard"),
    ("Plume", r"^Plume Design"),
    ("Arris / CommScope", r"^Commscope|^CommScope"),
    ("Sagemcom", r"^Sagemcom"),
    ("Vantiva / Technicolor", r"^Vantiva|^Technicolor"),
    ("NVIDIA", r"^NVIDIA|^Nvidia"),
    ("Hon Hai (Foxconn)", r"^Hon Hai"),
    ("Murata", r"^Murata Manufacturing"),
    ("AzureWave", r"^AzureWave"),
    ("Lite-On", r"^Liteon|^LITE-ON|^Lite-On"),
    ("Quanta", r"^Quanta Computer"),
    ("Wistron", r"^Wistron"),
    ("Texas Instruments", r"^Texas Instruments"),
    ("Silicon Labs", r"^Silicon Laboratories"),
    ("Realtek", r"^Realtek"),
    ("MediaTek", r"^MediaTek"),
    ("Broadcom", r"^Broadcom"),
    ("Qualcomm", r"^Qualcomm|^QUALCOMM"),
    ("Universal Electronics", r"^Universal Electronics, Inc"),
]


def main(path):
    compiled = [(name, re.compile(rx)) for name, rx in VENDORS]
    blocks = {name: [] for name, _ in VENDORS}
    for line in open(path, encoding="utf-8"):
        if line.startswith("#"):
            continue
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 3:
            continue
        prefix = cols[0].strip()
        if not re.fullmatch(r"[0-9A-F]{2}:[0-9A-F]{2}:[0-9A-F]{2}", prefix):
            continue   # 28- and 36-bit blocks (MA-M, MA-S) are skipped: lookups are by the first 3 octets only
        org = cols[2].strip()
        for name, rx in compiled:
            if rx.search(org):
                blocks[name].append(prefix.replace(":", ""))
                break
    out = sys.stdout
    total = sum(len(v) for v in blocks.values())
    out.write("// GENERATED by scripts/gen-oui.py from Wireshark's `manuf` (IEEE MA-L registry). Do not edit by hand.\n")
    out.write(f"// {total} 24-bit MAC prefixes for {sum(1 for v in blocks.values() if v)} common vendors.\n\n")
    out.write("extension OUI {\n")
    out.write("    /// (vendor, space-separated 6-hex-digit prefixes). Parsed once into a dictionary by `OUI.table`.\n")
    out.write("    static let packed: [(String, String)] = [\n")
    for name, _ in VENDORS:
        v = sorted(set(blocks[name]))
        if not v:
            continue
        out.write(f'        ("{name}", "{" ".join(v)}"),\n')
    out.write("    ]\n}\n")


if __name__ == "__main__":
    main(sys.argv[1])
