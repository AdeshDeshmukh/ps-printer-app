"""Submit a PostScript job through PAPPL and inspect its LPD output."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import socket
import subprocess
from tempfile import TemporaryDirectory
import time


PRINTER = "lpd-smoke"
DRIVER = "generic--postscript-printer--en"
MARKER = b"OpenPrinting LPD smoke test"
DOCUMENT = b"%!PS-Adobe-3.0\n/Helvetica findfont 12 scalefont setfont\n72 720 moveto\n(" + MARKER + b") show\nshowpage\n"


def receive_job(connection):
    """Acknowledge one LPD job with a control file and a data file."""
    with connection.makefile("rb") as stream:
        if stream.readline(512) != b"\x02capture\n":
            raise ValueError("Expected an LPD receive-job command for queue capture")
        connection.sendall(b"\0")

        payloads = {}
        for _ in range(2):
            command = stream.readline(512)
            kind = command[:1]
            fields = command[1:].split()
            if kind not in (b"\x02", b"\x03") or kind in payloads or len(fields) != 2:
                raise ValueError(f"Unexpected LPD file command: {command!r}")
            size = int(fields[0])
            if not 0 < size <= 1024 * 1024:
                raise ValueError(f"Unexpected LPD file size: {size}")
            connection.sendall(b"\0")
            payload = stream.read(size)
            if len(payload) != size or stream.read(1) != b"\0":
                raise ValueError("Invalid LPD payload length or terminator")
            payloads[kind] = payload
            connection.sendall(b"\0")

    return payloads[b"\x03"]


def capture_job(listener):
    connection, _ = listener.accept()
    with connection:
        connection.settimeout(10)
        return receive_job(connection)


def pappl(*options):
    result = subprocess.run(
        ["ps-printer-app", *options], check=True, text=True,
        stdout=subprocess.PIPE, timeout=15,
    )
    if result.stdout:
        print(result.stdout, end="", flush=True)
    return result.stdout.strip()


def main():
    socket_path = Path("/tmp/ps-printer-app1001.sock")
    for _ in range(60):
        if socket_path.is_socket():
            break
        time.sleep(0.25)
    else:
        raise TimeoutError(f"PAPPL socket did not appear at {socket_path}")

    with socket.socket() as listener, TemporaryDirectory() as directory:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(30)
        port = listener.getsockname()[1]
        uri = f"cups:lpd://127.0.0.1:{port}/capture?reserve=none"
        document = Path(directory) / "lpd-smoke.ps"
        document.write_bytes(DOCUMENT)

        pappl("add", "-d", PRINTER, "-m", DRIVER, "-v", uri)
        with ThreadPoolExecutor(max_workers=1) as pool:
            received = pool.submit(capture_job, listener)
            submission = pappl("submit", "-d", PRINTER, "-o", "document-format=application/postscript", str(document))
            payload = received.result(timeout=30)

    if b"%!PS" not in payload or MARKER not in payload:
        raise ValueError("LPD receiver did not get the expected PostScript document")

    job_id = submission.splitlines()[-1].removeprefix(f"{PRINTER}-")
    if not job_id.isdigit():
        raise ValueError(f"Unexpected PAPPL submission result: {submission!r}")
    for _ in range(10):
        if any(line.split()[:2] == [job_id, "completed"] for line in pappl("jobs", "-d", PRINTER).splitlines()):
            print(f"Job {job_id} completed and the LPD receiver got {len(payload)} bytes of PostScript.")
            return
        time.sleep(1)
    raise RuntimeError(f"PAPPL did not report job {job_id} completed")


if __name__ == "__main__":
    main()
