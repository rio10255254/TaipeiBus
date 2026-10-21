"""Read-only, locally saved TaipeiBus rendering diagnostics. No remote upload."""
from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timezone
import json
import logging
import os
from pathlib import Path
import re
import sys
import zipfile

BUNDLE = "com.rio10255254.TaipeiBus"
SYSTEM_RENDERERS = {"chronod", "liveactivitiesd", "SpringBoard", "runningboardd", "pluginkitd"}
RENDER_ERRORS = (
    "Archive was nil", "LiveActivity will be empty", "Unknown extension process",
    "Invalid or missing Program/ProgramArguments", "Failed to build view", "Failed to decode",
    "Unable to decode", "No matching ActivityConfiguration", "decode failure",
    "memory limit", "memory pressure", "invalid frame dimension", "connection invalidated",
)
PAYLOAD = re.compile(r"(?i)\b(content[-_ ]?state|latitude|longitude|coordinates|headline|nextInstruction|stopName|routeName|destination)\s*[=:]")


def redact(message: str) -> str:
    if PAYLOAD.search(message):
        return "[Navigation payload omitted]"
    message = re.sub(r"https?://\S+", "[url]", message)
    message = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "[email]", message)
    message = re.sub(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", "[id]", message)
    message = re.sub(r"\b\d{16,}\b", "[identifier]", message)
    message = re.sub(r"(?<!\w)-?\d{1,3}\.\d{3,}\s*[,; ]\s*-?\d{1,3}\.\d{3,}", "[coordinates]", message)
    message = re.sub(r"(?:/private/var/(?:mobile|containers)/|/Users/|[A-Za-z]:\\Users\\)\S+", "[private path]", message, flags=re.I)
    message = re.sub(r'"[^"\r\n]{1,500}"', '"[text]"', message)
    return message[:1800]


def filtered_record(process: str, message: str, level: str, timestamp: str) -> dict | None:
    own_app = process in {"TaipeiBus", "TaipeiBusWidgets"}
    references_app = "taipeibus" in message.lower()
    if not own_app and not (process in SYSTEM_RENDERERS and references_app):
        # A renderer may omit the app identity when it fails. Preserve only the
        # recognized generic failure phrase, never another app's raw message.
        if process not in SYSTEM_RENDERERS or level not in {"ERROR", "FAULT"}:
            return None
        phrases = [p for p in RENDER_ERRORS if p.lower() in message.lower()]
        if not phrases:
            return None
        message = "[Unscoped renderer error] " + "; ".join(phrases)
    return {"time": timestamp, "process": process, "level": level, "message": redact(message)}


def write_report(root: Path, metadata: dict, records: list[dict]) -> Path:
    root.mkdir(parents=True, exist_ok=False)
    (root / "summary.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    with (root / "rendering.jsonl").open("w", encoding="utf-8") as stream:
        for record in records:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")
    archive = root.with_suffix(".zip")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for file in sorted(root.iterdir()):
            z.write(file, arcname=file.name)
    return archive


async def capture(seconds: int, metadata: dict, records: list[dict], unattended: bool) -> None:
    from pymobiledevice3.usbmux import list_devices
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    from pymobiledevice3.services.os_trace import OsTraceService

    metadata["stage"] = "usb-discovery"
    devices = [d for d in await asyncio.wait_for(list_devices(), 10) if d.connection_type == "USB"]
    if len(devices) != 1:
        metadata["status"] = "no_usb_device" if not devices else "multiple_usb_devices"
        print("尚未找到 iPhone。請解鎖、按信任並重新連線。" if not devices else "請先只保留一台 iPhone 連線。")
        return
    metadata["stage"] = "trust"
    print("正在連接 iPhone；若出現信任提示，請在手機上允許。", flush=True)
    client = await asyncio.wait_for(create_using_usbmux(serial=devices[0].serial,
        connection_type="USB", label="TaipeiBus display diagnostics", pair_timeout=90), 95)
    async with client:
        metadata["stage"] = "version-check"
        for key in ("ProductType", "ProductVersion", "BuildVersion"):
            metadata[key] = await asyncio.wait_for(client.get_value(key=key), 15)
        async with InstallationProxyService(lockdown=client) as service:
            apps = await asyncio.wait_for(service.get_apps(bundle_identifiers=[BUNDLE]), 25)
        info = apps.get(BUNDLE)
        if not info:
            metadata["status"] = "app_not_installed"
            print("這台 iPhone 沒有找到台北公車的測試版。")
            return
        metadata["app"] = {key: info.get(key) for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")}
        print("已連接：iOS " + str(metadata["ProductVersion"]) + "，台北公車 " + str(info.get("CFBundleShortVersionString")) + " (" + str(info.get("CFBundleVersion")) + ")", flush=True)
        if not unattended:
            input("按 Enter 開始記錄；接著在手機重新開始導航，回主畫面、長按動態島並停留 20 秒。\n")
        metadata["stage"] = "recording"
        metadata["capture_started_utc"] = datetime.now(timezone.utc).isoformat()
        print(f"開始記錄，{seconds} 秒後會自動結束。請保持傳輸線連接。", flush=True)
        async with OsTraceService(lockdown=client) as service:
            try:
                async with asyncio.timeout(seconds):
                    async for entry in service.syslog():
                        process = entry.filename.replace("\\", "/").rsplit("/", 1)[-1]
                        record = filtered_record(process, entry.message, entry.level.name, entry.timestamp.isoformat())
                        if record and len(records) < 20000:
                            records.append(record)
            except TimeoutError:
                pass
        metadata["stage"] = "finished"
        metadata["status"] = "captured" if records else "no_relevant_records"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument("--unattended", action="store_true")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "reports")
    args = parser.parse_args()
    if not 5 <= args.seconds <= 300:
        parser.error("seconds must be between 5 and 300")
    # Third-party errors can include device identifiers. Preserve the error type
    # and selected status ourselves; do not tee raw library output into reports.
    logging.disable(logging.CRITICAL)
    print("台北公車 · 動態島顯示檢查\n只讀取紀錄，不會備份、修改或上傳手機資料。", flush=True)
    metadata = {"tool_version": 1, "status": "not_started", "library": "pymobiledevice3 11.40.2"}
    records: list[dict] = []
    try:
        asyncio.run(capture(args.seconds, metadata, records, args.unattended))
    except KeyboardInterrupt:
        metadata["status"] = "stopped_early"
    except Exception as error:
        metadata["status"] = "connection_error"
        metadata["error_type"] = type(error).__name__
        print("尚未完成連線或記錄。請確認手機仍解鎖且已按信任。", flush=True)
        if metadata.get("stage") == "usb-discovery":
            print("若這台 Windows 尚未安裝 Apple Devices，請從 Apple 官方說明安裝後再開啟：\nhttps://support.apple.com/zh-tw/108643", flush=True)
    metadata["retained_records"] = len(records)
    metadata["report_time_utc"] = datetime.now(timezone.utc).isoformat()
    folder = args.output / ("TaipeiBus-display-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    archive = write_report(folder, metadata, records)
    print("\n報告已儲存：" + str(archive), flush=True)
    print("完成記錄。" if metadata["status"] == "captured" else "報告也會保留這次未能完成的原因。", flush=True)
    return 0 if metadata["status"] == "captured" else 2


if __name__ == "__main__":
    raise SystemExit(main())
