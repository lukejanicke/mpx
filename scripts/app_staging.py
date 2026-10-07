"""Keep temporary app bundles out of search and unregister them before removal."""
from contextlib import contextmanager
from pathlib import Path
import signal
import subprocess
import tempfile


LSREGISTER = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")


@contextmanager
def temporary_app_directory(prefix):
    # SIGINT already raises KeyboardInterrupt. Convert normal termination signals
    # into an exception too, so both unregistration and directory cleanup run.
    def terminate(signum, frame):
        raise SystemExit(128 + signum)

    signals = (signal.SIGHUP, signal.SIGTERM)
    previous_handlers = {signum: signal.getsignal(signum) for signum in signals}
    try:
        for signum in signals:
            signal.signal(signum, terminate)
        with tempfile.TemporaryDirectory(prefix=prefix, suffix=".noindex") as staging:
            try:
                yield staging
            finally:
                app = Path(staging) / "mpx.app"
                if app.is_dir() and LSREGISTER.is_file():
                    subprocess.run([str(LSREGISTER), "-u", str(app)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   check=False)
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
