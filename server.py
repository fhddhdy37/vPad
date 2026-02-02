import asyncio
import json
import time
import websockets
import vgamepad as vg
import socket
import platform
import uuid

from zeroconf import ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

SERVICE_TYPE = "_phonepad._tcp.local."

def get_lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    finally:
        s.close()

def default_state():
    return {
        "a": False, "b": False, "x": False, "y": False,
        "lb": False, "rb": False,
        "+": False, "-": False,
        "ls": False, "rs": False,
        "dpad": "CENTER",
        "lx": 0.0, "ly": 0.0, "rx": 0.0, "ry": 0.0,
        "lt": 0.0, "rt": 0.0,
        "zl": False, "zr": False,
        "home": False, "capture": False,
    }

def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v

def f01(v):
    try:
        return clamp(float(v), 0.0, 1.0)
    except:
        return 0.0

def f11(v):
    try:
        return clamp(float(v), -1.0, 1.0)
    except:
        return 0.0

def set_btn(gp, cond: bool, button):
    if cond:
        gp.press_button(button)
    else:
        gp.release_button(button)

def apply_state(gp, s: dict):
    # ----- Face -----
    set_btn(gp, bool(s.get("a")), vg.XUSB_BUTTON.XUSB_GAMEPAD_A)
    set_btn(gp, bool(s.get("b")), vg.XUSB_BUTTON.XUSB_GAMEPAD_B)
    set_btn(gp, bool(s.get("x")), vg.XUSB_BUTTON.XUSB_GAMEPAD_X)
    set_btn(gp, bool(s.get("y")), vg.XUSB_BUTTON.XUSB_GAMEPAD_Y)

    # ----- Shoulders -----
    set_btn(gp, bool(s.get("lb")), vg.XUSB_BUTTON.XUSB_GAMEPAD_LEFT_SHOULDER)
    set_btn(gp, bool(s.get("rb")), vg.XUSB_BUTTON.XUSB_GAMEPAD_RIGHT_SHOULDER)

    # ----- Start/Back -----
    set_btn(gp, bool(s.get("+")), vg.XUSB_BUTTON.XUSB_GAMEPAD_START)
    set_btn(gp, bool(s.get("-")), vg.XUSB_BUTTON.XUSB_GAMEPAD_BACK)

    # ----- Stick Click -----
    set_btn(gp, bool(s.get("ls")), vg.XUSB_BUTTON.XUSB_GAMEPAD_LEFT_THUMB)
    set_btn(gp, bool(s.get("rs")), vg.XUSB_BUTTON.XUSB_GAMEPAD_RIGHT_THUMB)

    # ----- D-Pad -----
    gp.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_UP)
    gp.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_DOWN)
    gp.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_LEFT)
    gp.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_RIGHT)

    d = str(s.get("dpad", "CENTER")).upper()
    if d in ("UP", "UP_LEFT", "UP_RIGHT"):
        gp.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_UP)
    if d in ("DOWN", "DOWN_LEFT", "DOWN_RIGHT"):
        gp.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_DOWN)
    if d in ("LEFT", "UP_LEFT", "DOWN_LEFT"):
        gp.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_LEFT)
    if d in ("RIGHT", "UP_RIGHT", "DOWN_RIGHT"):
        gp.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_RIGHT)

    # ----- Sticks -----
    lx = f11(s.get("lx", 0.0))
    ly = f11(s.get("ly", 0.0))
    rx = f11(s.get("rx", 0.0))
    ry = f11(s.get("ry", 0.0))

    gp.left_joystick_float(x_value_float=lx, y_value_float=ly)
    gp.right_joystick_float(x_value_float=rx, y_value_float=ry)

    # ----- Triggers -----
    lt = f01(s.get("lt", 0.0))
    rt = f01(s.get("rt", 0.0))

    if bool(s.get("zl")) and lt == 0.0:
        lt = 1.0
    if bool(s.get("zr")) and rt == 0.0:
        rt = 1.0

    gp.left_trigger_float(value_float=lt)
    gp.right_trigger_float(value_float=rt)

    gp.update()

async def register_mdns(ip: str, port: int, server_name: str, server_id: str):
    # 서버마다 고유한 Service Name을 만듭니다.
    # (동일 네트워크에서 여러 서버가 동시에 광고 가능)
    instance = f"PhonePad-{server_name}-{server_id}"
    service_name = f"{instance}.{SERVICE_TYPE}"

    azc = AsyncZeroconf()
    # TXT 레코드에 OS와 표시명(display) 등 추가로 포함합니다.
    info = ServiceInfo(
        SERVICE_TYPE,
        service_name,
        addresses=[socket.inet_aton(ip)],
        port=port,
        properties={
            b"name": server_name.encode("utf-8"),
            b"display": server_name.encode("utf-8"),
            b"id": server_id.encode("utf-8"),
            b"ip": ip.encode("utf-8"),
            b"port": str(port).encode("utf-8"),
            b"os": platform.system().encode("utf-8"),
        },
    )
    await azc.async_register_service(info)
    print(f"[mDNS] {service_name} -> {ip}:{port} (name={server_name}, id={server_id}, os={platform.system()})")
    return azc, info

async def ws_handler(ws):
    # 클라이언트별 컨트롤러/상태 (중요: 여러 클라이언트가 각각 독립)
    gp = vg.VX360Gamepad()
    state = default_state()
    last_update = time.time()

    peer = ws.remote_address
    print(f"CONNECTED: {peer} -> new controller")

    async def watchdog():
        nonlocal last_update, state
        while True:
            if time.time() - last_update > 0.5:
                state = default_state()
                apply_state(gp, state)
            await asyncio.sleep(0.1)

    wd_task = asyncio.create_task(watchdog())

    try:
        async for msg in ws:
            data = json.loads(msg)
            if isinstance(data, dict):
                state.update(data)
                last_update = time.time()
                # 디버그(필요 시)
                # print("RX:", {k: state.get(k) for k in ("a","b","x","y","lb","rb","+","-","dpad","lt","rt","ls","rs")})
                apply_state(gp, state)
    except Exception as e:
        print("WS ERROR:", e)
    finally:
        wd_task.cancel()
        try:
            gp.reset()
            gp.update()
        except Exception:
            pass
        print(f"DISCONNECTED: {peer}")

async def main():
    ip = get_lan_ip()
    port = 8765

    server_name = platform.node() or "Server"
    server_id = uuid.uuid4().hex[:6]

    azc, info = await register_mdns(ip, port, server_name, server_id)

    try:
        print(f"Listening on ws://0.0.0.0:{port} (advertised name: {server_name}, id: {server_id})")
        async with websockets.serve(ws_handler, "0.0.0.0", port):
            await asyncio.Future()  # run forever
    except KeyboardInterrupt:
        print("Interrupted, shutting down...")
    finally:
        try:
            await azc.async_unregister_service(info)
        except Exception:
            pass
        await azc.async_close()

if __name__ == "__main__":
    asyncio.run(main())
