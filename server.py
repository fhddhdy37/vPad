import asyncio
import json
import time
import websockets
import vgamepad as vg
import socket
from zeroconf import Zeroconf, ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

# gp = vg.VX360Gamepad()

SERVICE_TYPE = "_phonepad._tcp.local."
SERVICE_NAME = "PhonePad._phonepad._tcp.local."

def get_lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # 기본 라우팅 인터페이스의 LAN IP를 얻음 (실제 연결은 안 됨)
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    finally:
        s.close()

async def register_mdns(ip: str, port: int):
    azc = AsyncZeroconf()
    info = ServiceInfo(
        SERVICE_TYPE,
        SERVICE_NAME,
        addresses=[socket.inet_aton(ip)],
        port=port,
        properties={},
    )
    await azc.async_register_service(info)
    print(f"[mDNS] {SERVICE_NAME} -> {ip}:{port}")
    return azc, info

# state = {
#     "a": False, "b": False, "x": False, "y": False,
#     "lb": False, "rb": False,
#     "+": False, "-": False,
#     "ls": False, "rs": False,
#     "dpad": "CENTER",
#     "lx": 0.0, "ly": 0.0, "rx": 0.0, "ry": 0.0,
#     "lt": 0.0, "rt": 0.0,
#     # 선택: 앱에서 보내면 사용
#     "zl": False, "zr": False, "home": False, "capture": False,
# }

last_update = 0.0

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
    # Android에서 +/back으로 보내거나, plus/minus로 보내면 여기서 맞추셔도 됩니다.
    set_btn(gp, bool(s.get("+")), vg.XUSB_BUTTON.XUSB_GAMEPAD_START)
    set_btn(gp, bool(s.get("-")), vg.XUSB_BUTTON.XUSB_GAMEPAD_BACK)

    # ----- Stick Click -----
    set_btn(gp, bool(s.get("ls")), vg.XUSB_BUTTON.XUSB_GAMEPAD_LEFT_THUMB)
    set_btn(gp, bool(s.get("rs")), vg.XUSB_BUTTON.XUSB_GAMEPAD_RIGHT_THUMB)

    # ----- D-Pad -----
    # 먼저 전체 해제 후 필요한 것만 누르기
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

    # vgamepad는 float 기준: -1..1 (y는 보통 위가 +가 되도록 앱에서 이미 뒤집어 보냄)
    gp.left_joystick_float(x_value_float=lx, y_value_float=ly)
    gp.right_joystick_float(x_value_float=rx, y_value_float=ry)

    # ----- Triggers -----
    # 앱에서 lt/rt(0..1) 보내는 걸 우선 사용
    lt = f01(s.get("lt", 0.0))
    rt = f01(s.get("rt", 0.0))

    # 만약 zl/zr를 디지털로만 보내고 lt/rt를 안 보내면, zl/zr로 트리거를 1로 올리기
    if bool(s.get("zl")) and lt == 0.0:
        lt = 1.0
    if bool(s.get("zr")) and rt == 0.0:
        rt = 1.0

    gp.left_trigger_float(value_float=lt)
    gp.right_trigger_float(value_float=rt)

    gp.update()

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
    }


async def ws_handler(ws):
    gp = vg.VX360Gamepad()   # ★ 클라이언트마다 컨트롤러 생성
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
                apply_state(gp, state)
    except Exception as e:
        print("WS ERROR:", e)
    finally:
        wd_task.cancel()
        gp.reset()
        gp.update()
        print(f"DISCONNECTED: {peer}")

async def watchdog():
    global last_update, state
    while True:
        if last_update and (time.time() - last_update > 0.5):
            # 입력 끊기면 중립
            state.update({
                "a": False, "b": False, "x": False, "y": False,
                "lb": False, "rb": False,
                "+": False, "-": False,
                "ls": False, "rs": False,
                "dpad": "CENTER",
                "lx": 0.0, "ly": 0.0, "rx": 0.0, "ry": 0.0,
                "lt": 0.0, "rt": 0.0,
                "zl": False, "zr": False,
            })
            apply_state(state)
            last_update = 0.0
        await asyncio.sleep(0.1)

async def main():
    ip = get_lan_ip()
    azc, info = await register_mdns(ip, 8765)
    try:
        print("Listening on ws://0.0.0.0:8765")
        async with websockets.serve(ws_handler, "0.0.0.0", 8765):
            await watchdog()
    finally:
        try:
            await azc.async_unregister_service(info)
        except Exception:
            pass
        await azc.async_close()

if __name__ == "__main__":
    asyncio.run(main())
