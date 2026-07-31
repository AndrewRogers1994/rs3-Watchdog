import sqlite3, shutil, tempfile, os, json

for src in [
    r"C:\ProgramData\Jagex\RuneScape-BETA\PluginData.db",
    r"D:\SteamLibrary\steamapps\common\RuneScape\RuneScape-BETA\PluginData.db",
]:
    print("===", src)
    if not os.path.exists(src):
        print("missing")
        continue
    tmp = os.path.join(tempfile.gettempdir(), "wd_probe_" + os.path.basename(os.path.dirname(src)) + ".db")
    shutil.copy2(src, tmp)
    con = sqlite3.connect(tmp)
    cur = con.cursor()
    cur.execute("SELECT DISTINCT PluginID FROM DataStore")
    print("plugins:", [r[0] for r in cur.fetchall()])
    cur.execute("SELECT Key, Type, length(Value) FROM DataStore WHERE PluginID='Watchdog'")
    keys = cur.fetchall()
    print("Watchdog keys:", keys)
    for want in ("global", "mgr_probe_log", "mgr_probe_run", "mgr_probe_stop", "crash_probe_log", "crash_probe_run"):
        cur.execute(
            "SELECT Type, Value FROM DataStore WHERE PluginID=? AND Key=?",
            ("Watchdog", want),
        )
        row = cur.fetchone()
        if not row:
            print(want, ": absent")
            continue
        typ, val = row
        if want.endswith("_run") and val and len(val) == 4:
            import struct
            print(want, ":", struct.unpack("<i", val)[0])
            continue
        s = val.rstrip(b"\x00").decode("utf-8", errors="replace")
        if want == "global":
            try:
                doc = json.loads(s)
                entries = doc.get("entries") or []
                print("global entries:", len(entries))
                for e in entries[:15]:
                    print(" ", e.get("id"), e.get("kind"), e.get("name"))
            except Exception as ex:
                print("global json err", ex, s[:200])
        else:
            print(want, "len", len(s))
            print(s[-4000:] if len(s) > 4000 else s)
    con.close()
