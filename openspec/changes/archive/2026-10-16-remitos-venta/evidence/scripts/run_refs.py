import runpy, subprocess, sys, shutil
real = subprocess.run
SHIM = "C:/Users/Usuario/Desktop/EIE/scratchpad-remitos/bin/psql"
def patched(cmd, *a, **k):
    if isinstance(cmd, list) and cmd and cmd[0] == "psql":
        cmd = ["C:/Program Files/Git/usr/bin/bash.exe", SHIM] + cmd[1:]
    return real(cmd, *a, **k)
subprocess.run = patched
_which = shutil.which
shutil.which = lambda n, *a, **k: "psql-shim" if n == "psql" else _which(n, *a, **k)
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
