import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:flutter/gestures.dart';
import 'package:vibration/vibration.dart';


const String kServiceType = '_phonepad._tcp.local';
const String kTargetNameContains = 'PhonePad';

class DiscoveredService {
  final String instance;
  final String display;
  final String id;
  final String host;
  final int port;

  DiscoveredService({
    required this.instance,
    required this.display,
    required this.id,
    required this.host,
    required this.port,
  });

  String get label => '$display ($host:$port)';
}

@immutable
class ControllerState {
  final bool a, b, x, y;
  final bool lb, rb, zl, zr;
  // final bool plus, minus, home, capture;
  final bool plus, minus;
  final bool ls, rs;
  final String dpad; // UP/DOWN/LEFT/RIGHT/CENTER...
  final double lx, ly, rx, ry; // -1..1
  final double lt, rt; // 0..1

  const ControllerState({
    this.a = false,
    this.b = false,
    this.x = false,
    this.y = false,
    this.lb = false,
    this.rb = false,
    this.zl = false,
    this.zr = false,
    this.plus = false,
    this.minus = false,
    // this.home = false,
    // this.capture = false,
    this.ls = false,
    this.rs = false,
    this.dpad = 'CENTER',
    this.lx = 0,
    this.ly = 0,
    this.rx = 0,
    this.ry = 0,
    this.lt = 0,
    this.rt = 0,
  });

  Map<String, dynamic> toJson() => {
        'a': a,
        'b': b,
        'x': x,
        'y': y,
        'lb': lb,
        'rb': rb,
        '-': minus,
        '+': plus,
        'ls': ls,
        'rs': rs,
        'dpad': dpad,
        'lx': lx,
        'ly': ly,
        'rx': rx,
        'ry': ry,
        'lt': lt,
        'rt': rt,
        'zl': zl,
        'zr': zr,
        // 'home': home,
        // 'capture': capture,
      };

  @override
  bool operator ==(Object other) {
    return other is ControllerState &&
        a == other.a &&
        b == other.b &&
        x == other.x &&
        y == other.y &&
        lb == other.lb &&
        rb == other.rb &&
        zl == other.zl &&
        zr == other.zr &&
        plus == other.plus &&
        minus == other.minus &&
        // home == other.home &&
        // capture == other.capture &&
        ls == other.ls &&
        rs == other.rs &&
        dpad == other.dpad &&
        lx == other.lx &&
        ly == other.ly &&
        rx == other.rx &&
        ry == other.ry &&
        lt == other.lt &&
        rt == other.rt;
  }

  @override
  int get hashCode => Object.hashAll([
    a, b, x, y,
    lb, rb, zl, zr,
    // plus, minus, home, capture,
    plus, minus, 
    ls, rs, dpad,
    lx, ly, rx, ry,
    lt, rt,
  ]);


  ControllerState copyWith({
    bool? a,
    bool? b,
    bool? x,
    bool? y,
    bool? lb,
    bool? rb,
    bool? zl,
    bool? zr,
    bool? plus,
    bool? minus,
    // bool? home,
    // bool? capture,
    bool? ls,
    bool? rs,
    String? dpad,
    double? lx,
    double? ly,
    double? rx,
    double? ry,
    double? lt,
    double? rt,
  }) {
    return ControllerState(
      a: a ?? this.a,
      b: b ?? this.b,
      x: x ?? this.x,
      y: y ?? this.y,
      lb: lb ?? this.lb,
      rb: rb ?? this.rb,
      zl: zl ?? this.zl,
      zr: zr ?? this.zr,
      plus: plus ?? this.plus,
      minus: minus ?? this.minus,
      // home: home ?? this.home,
      // capture: capture ?? this.capture,
      ls: ls ?? this.ls,
      rs: rs ?? this.rs,
      dpad: dpad ?? this.dpad,
      lx: lx ?? this.lx,
      ly: ly ?? this.ly,
      rx: rx ?? this.rx,
      ry: ry ?? this.ry,
      lt: lt ?? this.lt,
      rt: rt ?? this.rt,
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const PhonePadApp());
}

class PhonePadApp extends StatelessWidget {
  const PhonePadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PhonePad',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const ControllerPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ControllerPage extends StatefulWidget {
  const ControllerPage({super.key});
  @override
  State<ControllerPage> createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage> {
  ControllerState _state = const ControllerState();
  ControllerState? _lastSent;

  // String _status = 'connecting...';

  MDnsClient? _mdns;
  StreamSubscription? _discoverySub;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Map<String, DiscoveredService> _services = {};
  String? _connectedServiceId;

  Timer? _sendTimer;
  DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
  super.initState();
  _startDiscovery();

  _sendTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
    if (_ws == null) return;

    final now = DateTime.now();
    final shouldHeartbeat =
        now.difference(_lastSentAt) >= const Duration(milliseconds: 150); // 0.5s보다 짧게

    final changed = (_lastSent != _state);

    if (changed || shouldHeartbeat) {
      _ws!.sink.add(jsonEncode(_state.toJson()));
      _lastSent = _state;
      _lastSentAt = now;
    }
  });
}
  // void initState() {
  //   super.initState();
  //   _startDiscovery();

  //   // Kotlin처럼 60Hz로 "상태 변경 시에만" 송신 :contentReference[oaicite:5]{index=5}
  //   _sendTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
  //     if (_ws == null) return;
  //     if (_lastSent == _state) return;
  //     _ws!.sink.add(jsonEncode(_state.toJson()));
  //     _lastSent = _state;
  //   });
  // }

  @override
  void dispose() {
    _sendTimer?.cancel();
    _stopDiscovery();
    _closeWs();
    super.dispose();
  }

  // void _setStatus(String s) {
  //   if (!mounted) return;
  //   setState(() => _status = s);
  // }

  void _apply(ControllerState Function(ControllerState) fn) {
    setState(() => _state = fn(_state));
  }

  Future<void> _startDiscovery() async {
    await _stopDiscovery();
    // _setStatus('discovering...');

    final client = MDnsClient();
    _mdns = client;
    await client.start();

    // PTR: _phonepad._tcp.local -> instanceName
    _discoverySub = client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer(kServiceType),
    ).listen((ptr) async {
      final instance = ptr.domainName;
      if (!instance.contains(kTargetNameContains)) return;

      // _setStatus('found: $instance (resolving)');

      // SRV: instance -> target + port
      await for (final srv in client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(instance),
      )) {
        final target = srv.target;
        final port = srv.port;

        // A/AAAA: target -> IP
        final ips = <InternetAddress>[];

        await for (final a in client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(target),
        )) {
          ips.add(a.address);
        }
        await for (final aaaa in client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv6(target),
        )) {
          ips.add(aaaa.address);
        }

        if (ips.isEmpty) return;

        // PTR 인스턴스 이름 예: PhonePad-MyPC-ab12cd._phonepad._tcp.local.
        final host = ips.first.address;
        // 인스턴스에서 display, id를 추출 (없으면 instance 전체 사용)
        String display = instance;
        String id = instance;
        final reg = RegExp(r'^PhonePad-(.+)-([0-9A-Fa-f]+)\._phonepad\._tcp\.local\.?');
        final m = reg.firstMatch(instance);
        if (m != null) {
          display = m.group(1) ?? instance;
          id = m.group(2) ?? instance;
        } else {
          final i = instance.indexOf('.');
          if (i > 0) display = instance.substring(0, i);
        }

        final key = id;
        setState(() {
          _services[key] = DiscoveredService(
            instance: instance,
            display: display,
            id: id,
            host: host,
            port: port,
          );
        });
      }
    });
  }

  Future<void> _stopDiscovery() async {
    await _discoverySub?.cancel();
    _discoverySub = null;

    final client = _mdns;
    _mdns = null;
    if (client != null) {
      client.stop();
    }
  }

  void _connectWs(String host, int port, {String? serviceId}) {
    if (_ws != null) return; // 중복 연결 방지

    final uri = Uri.parse('ws://$host:$port');

    try {
      final channel = WebSocketChannel.connect(uri);
      _ws = channel;

      setState(() => _connectedServiceId = serviceId);

      _wsSub = channel.stream.listen(
        (_) {},
        onError: (e) {
          _closeWs();
          _startDiscovery(); // 실패 시 다시 탐색
        },
        onDone: () {
          _closeWs();
          _startDiscovery(); // 종료 시 다시 탐색
        },
      );
    } catch (e) {
      _closeWs();
      _startDiscovery();
    }
  }

  void _closeWs() {
    _wsSub?.cancel();
    _wsSub = null;
    try {
      _ws?.sink.close(ws_status.goingAway);
    } catch (_) {}
    _ws = null;
    if (_connectedServiceId != null) {
      setState(() => _connectedServiceId = null);
    }
  }

  // void _updateState(ControllerState s) => setState(() => _state = s);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        // top: false,
        // bottom: false,
        child: Container(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              // Kotlin에서는 status Text를 주석 처리했지만 디버깅용으로 남김 :contentReference[oaicite:10]{index=10}
              // Align(
              //   alignment: Alignment.centerLeft,
              //   child: Text(
              //     'Status: $_status',
              //     style: Theme.of(context).textTheme.bodySmall,
              //   ),
              // ),
              // Controller layout fills available space. Place the Servers button
              // as an overlay so it doesn't push the controller UI up.
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: SwitchControllerLayout(
                        state: _state,
                        apply: _apply,
                      ),
                    ),
                    // floating button at bottom center, does not affect layout sizing
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 12,
                      child: Center(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            showModalBottomSheet<void>(
                              context: context,
                              builder: (ctx) {
                                final services = _services.values.toList();
                                if (services.isEmpty) {
                                  return const Padding(
                                    padding: EdgeInsets.all(16.0),
                                    child: Text('No servers found'),
                                  );
                                }
                                return ListView.builder(
                                  itemCount: services.length,
                                  itemBuilder: (c, i) {
                                    final s = services[i];
                                    final isConnected = (_connectedServiceId == s.id);
                                    return ListTile(
                                      title: Text(s.display),
                                      subtitle: Text('${s.host}:${s.port}'),
                                      trailing: isConnected
                                          ? const Text('Connected')
                                          : ElevatedButton(
                                              onPressed: () {
                                                Navigator.of(ctx).pop();
                                                _stopDiscovery();
                                                _connectWs(s.host, s.port, serviceId: s.id);
                                              },
                                              child: const Text('Connect'),
                                            ),
                                    );
                                  },
                                );
                              },
                            );
                          },
                          // icon: const Icon(Icons.wifi),
                          label: Text('Servers (${_services.length})'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------------- UI ---------------- */

class SwitchControllerLayout extends StatelessWidget {
  final ControllerState state;
  final void Function(ControllerState Function(ControllerState)) apply;

  const SwitchControllerLayout({
    super.key,
    required this.state,
    required this.apply,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final h = c.maxHeight;

      // Base design (tuned for Galaxy S10 5G landscape), then scaled to fit smaller screens (e.g., Z Flip).
      const designW = 800.0;
      const designH = 420.0;
      final scale = (w / designW < h / designH) ? (w / designW) : (h / designH);

      double s(double v) => (v * scale).clamp(0.0, 10000.0);

      final stickSize = s(125);
      final dpadSize = s(150);

      final shoulderW = s(140); // 70 * 3
      final shoulderH = s(32);
      final softGuide = s(20);

      final centerBtnW = s(54);
      final centerBtnH = s(34);
      final centerGap = s(18);
      final midGap = s(30);
      final colGap = s(30);
      final betweenCols = s(70);

      return Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SizedBox(
                width: shoulderW,
                child: Column(
                  children: [
                    HoldButton(
                      label: 'ZL',
                      pressed: state.zl,
                      width: shoulderW,
                      height: shoulderH,
                      capsule: true,
                      onPressedChange: (p) => apply((s)=>
                        s.copyWith(zl: p, lt: p ? 1.0 : 0.0),
                      ),
                    ),
                    const SizedBox(height: 8),
                    HoldButton(
                      label: 'L',
                      pressed: state.lb,
                      width: shoulderW,
                      height: shoulderH,
                      capsule: true,
                      onPressedChange: (p) => apply((s)=>s.copyWith(lb: p)),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  HoldButton(
                    label: '−',
                    pressed: state.minus,
                    width: centerBtnW,
                    height: centerBtnH,
                    capsule: true,
                    onPressedChange: (p) => apply((s)=>s.copyWith(minus: p)),
                  ),
                  SizedBox(width: centerGap),
                  HoldButton(
                    label: '+',
                    pressed: state.plus,
                    width: centerBtnW,
                    height: centerBtnH,
                    capsule: true,
                    onPressedChange: (p) => apply((s)=>s.copyWith(plus: p)),
                  ),
                ],
              ),
              SizedBox(
                width: shoulderW,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    HoldButton(
                      label: 'ZR',
                      pressed: state.zr,
                      width: shoulderW,
                      height: shoulderH,
                      capsule: true,
                      onPressedChange: (p) => apply((s)=>
                        s.copyWith(zr: p, rt: p ? 1.0 : 0.0),
                      ),
                    ),
                    const SizedBox(height: 8),
                    HoldButton(
                      label: 'R',
                      pressed: state.rb,
                      width: shoulderW,
                      height: shoulderH,
                      capsule: true,
                      onPressedChange: (p) => apply((s)=>s.copyWith(rb: p)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: midGap),
          Expanded(
            child: Row(
              children: [
                SizedBox(width: softGuide),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Joystick(
                        size: stickSize,
                        onMove: (x, y) => apply((s)=>s.copyWith(lx: x, ly: y)),
                        onPress: (p) => apply((s)=>s.copyWith(ls: p)),
                      ),
                      SizedBox(height: colGap),
                      DPadCross(
                          size: dpadSize,
                          value: state.dpad,
                          onChange: (d) => apply((s)=>s.copyWith(dpad: d)),
                        ),
                    ],
                  ),
                ),
                SizedBox(width: betweenCols),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      ABXYCluster(
                        size: dpadSize,
                        a: state.a,
                        b: state.b,
                        x: state.x,
                        y: state.y,
                        onA: (p) => apply((s)=>s.copyWith(a: p)),
                        onB: (p) => apply((s)=>s.copyWith(b: p)),
                        onX: (p) => apply((s)=>s.copyWith(x: p)),
                        onY: (p) => apply((s)=>s.copyWith(y: p)),
                      ),
                      SizedBox(height: colGap),
                      Joystick(
                        size: stickSize,
                        onMove: (x, y) => apply((s)=>s.copyWith(rx: x, ry: y)),
                        onPress: (p) => apply((s)=>s.copyWith(rs: p)),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: softGuide),
              ],
            ),
          ),
        ],
      );
    });
  }
}

class HoldButton extends StatelessWidget {
  final String label;
  final bool pressed;
  final double width;
  final double height;
  final ValueChanged<bool> onPressedChange;

  // 추가
  final bool capsule;

  const HoldButton({
    super.key,
    required this.label,
    required this.pressed,
    required this.onPressedChange,
    this.width = 72,
    this.height = 44,
    this.capsule = false, // 기본은 기존처럼 원형
  });

  @override
  Widget build(BuildContext context) {
    final bg = pressed
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.surfaceVariant;
    final fg = pressed
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return Listener(
      onPointerDown: (_) {
        // Try device-level vibration first (vibration package). If unavailable,
        // fall back to Flutter's HapticFeedback.
        try {
          Vibration.hasVibrator().then((has) {
            if (has == true) {
              try {
                Vibration.vibrate(duration: 2);
              } catch (_) {
                try {
                  HapticFeedback.lightImpact();
                } catch (_) {}
              }
            } else {
              try {
                HapticFeedback.lightImpact();
              } catch (_) {}
            }
          });
        } catch (_) {
          try {
            HapticFeedback.lightImpact();
          } catch (_) {}
        }
        onPressedChange(true);
      },
      onPointerUp: (_) => onPressedChange(false),
      onPointerCancel: (_) => onPressedChange(false),
      child: Container(
        width: width,
        height: height,
        decoration: capsule
            ? BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(height / 2), // 캡슐
              )
            : BoxDecoration(
                color: bg,
                shape: BoxShape.circle, // 기존 동작 유지
              ),
        alignment: Alignment.center,
        child: Text(label,
            style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
      ),
    );
  }
}


class ABXYCluster extends StatelessWidget {
  final bool a, b, x, y;
  final ValueChanged<bool> onA, onB, onX, onY;
  final double size;

  const ABXYCluster({
    super.key,
    required this.a,
    required this.b,
    required this.x,
    required this.y,
    required this.onA,
    required this.onB,
    required this.onX,
    required this.onY,
    this.size = 150,
  });

  @override
  Widget build(BuildContext context) {
    final btn = size * 0.387; // 58 / 150
    final armInset = (size * 0.0067).clamp(1.0, 8.0); // 1 / 150

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: armInset,
            child: HoldButton(label: 'X', pressed: x, width: btn, height: btn, onPressedChange: onX),
          ),
          Positioned(
            bottom: armInset,
            child: HoldButton(label: 'B', pressed: b, width: btn, height: btn, onPressedChange: onB),
          ),
          Positioned(
            left: armInset,
            child: HoldButton(label: 'Y', pressed: y, width: btn, height: btn, onPressedChange: onY),
          ),
          Positioned(
            right: armInset,
            child: HoldButton(label: 'A', pressed: a, width: btn, height: btn, onPressedChange: onA),
          ),
        ],
      ),
    );
  }
}

class Joystick extends StatefulWidget {
  final double size;
  final void Function(double x, double y) onMove; // -1..1
  final ValueChanged<bool> onPress; // LS/RS

  const Joystick({
    super.key,
    required this.size,
    required this.onMove,
    required this.onPress,
  });

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  Offset knob = Offset.zero;

  int? _activePointer;
  Offset? _downPos;
  Offset? _lastPos;
  bool _isDown = false;

  Timer? _lpTimer;
  bool _stickClicked = false;

  static const Duration _longPressTime = Duration(milliseconds: 150);
  static const double _moveSlopPx = 6.0;

  @override
  void initState() {
    super.initState();
    // 전역 포인터 라우트: 조이스틱이 Up/Cancel을 못 받아도 여기서 강제 해제
    GestureBinding.instance.pointerRouter.addGlobalRoute(_globalPointerRoute);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_globalPointerRoute);
    _cancelLongPress();
    super.dispose();
  }

  void _globalPointerRoute(PointerEvent event) {
    final p = _activePointer;
    if (p == null) return;

    if (event.pointer != p) return;

    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _endInteraction(force: true);
    }
  }

  void _cancelLongPress() {
    _lpTimer?.cancel();
    _lpTimer = null;
  }

  void _startLongPressTimer() {
    _cancelLongPress();
    _lpTimer = Timer(_longPressTime, () {
      if (!mounted) return;
      if (!_isDown) return;
      if (_activePointer == null) return;
      final dp = _downPos;
      final lp = _lastPos;
      if (dp == null || lp == null) return;

      // "가만히 눌렀을 때만" 롱프레스 인정
      if ((lp - dp).distance <= _moveSlopPx) {
        if (!_stickClicked) {
          setState(() => _stickClicked = true);
          // 롱프레스가 인정될 때 진동을 줌
          try {
            Vibration.hasVibrator().then((has) {
              if (has == true) {
                try {
                  Vibration.vibrate(duration: 3);
                } catch (_) {
                  try {
                    HapticFeedback.lightImpact();
                  } catch (_) {}
                }
              } else {
                try {
                  HapticFeedback.lightImpact();
                } catch (_) {}
              }
            });
          } catch (_) {
            try {
              HapticFeedback.lightImpact();
            } catch (_) {}
          }

          widget.onPress(true); // LS/RS 눌림
        }
      }
    });
  }

  void _endInteraction({required bool force}) {
    if (!_isDown && !force) return;

    _isDown = false;
    _cancelLongPress();

    // LS/RS 해제 보장
    if (_stickClicked) {
      _stickClicked = false;
      widget.onPress(false);
      if (mounted) setState(() {}); // 눌림 표시 갱신
    }

    _activePointer = null;
    _downPos = null;
    _lastPos = null;

    // 스틱 축도 원점으로 복귀
    _resetStick();
  }

  void _emitStick(Offset off, double maxR) {
    final nx = (off.dx / maxR).clamp(-1.0, 1.0);
    final ny = (-off.dy / maxR).clamp(-1.0, 1.0);
    const dz = 0.12;
    final fx = (nx.abs() < dz) ? 0.0 : nx;
    final fy = (ny.abs() < dz) ? 0.0 : ny;
    widget.onMove(fx, fy);
  }

  void _resetStick() {
    if (!mounted) return;
    setState(() => knob = Offset.zero);
    // maxR은 build에서 계산되므로, reset 시 0,0만 전달
    widget.onMove(0.0, 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.size / 2;
    final knobRadius = radius * 0.35;
    final maxR = radius - knobRadius;

    Offset clampToCircle(Offset v) {
      final len = v.distance;
      if (len > maxR && len > 0) return v * (maxR / len);
      return v;
    }

    void updateFromLocalPos(Offset localPos) {
      _lastPos = localPos;

      final center = Offset(radius, radius);
      final v = localPos - center;
      final clamped = clampToCircle(v);

      setState(() => knob = clamped);
      _emitStick(clamped, maxR);

      // 움직이면 롱프레스 취소(“가만히 눌렀을 때만” 원하신 조건)
      final dp = _downPos;
      if (dp != null && (localPos - dp).distance > _moveSlopPx) {
        _cancelLongPress();
      }
    }

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if (_activePointer != null) return; // 첫 포인터만
        _activePointer = e.pointer;
        _isDown = true;
        _downPos = e.localPosition;
        _lastPos = e.localPosition;

        // 롱프레스 타이머 시작
        _startLongPressTimer();

        // 드래그 시작 시 바로 축 반영은 원하시면 유지, 원치 않으면 아래 줄 제거 가능
        updateFromLocalPos(e.localPosition);
      },
      onPointerMove: (e) {
        if (e.pointer != _activePointer) return;
        updateFromLocalPos(e.localPosition);
      },
      onPointerUp: (e) {
        if (e.pointer != _activePointer) return;
        _endInteraction(force: false);
      },
      onPointerCancel: (e) {
        if (e.pointer != _activePointer) return;
        _endInteraction(force: true);
      },
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: _JoystickPainter(knob: knob, pressed: _stickClicked),
        ),
      ),
    );
  }
}

class _JoystickPainter extends CustomPainter {
  final Offset knob;
  final bool pressed;

  _JoystickPainter({required this.knob, required this.pressed});

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    final knobRadius = radius * 0.35;
    final center = Offset(radius, radius);

    final bg = Paint()..color = const Color(0xFF2E2E2E);
    final inner = Paint()..color = const Color(0xFF3A3A3A);
    final knobPaint = Paint()..color = pressed ? const Color(0xFF6E6E6E) : const Color(0xFF5A5A5A);

    canvas.drawCircle(center, radius, bg);
    canvas.drawCircle(center, radius * 0.78, inner);
    canvas.drawCircle(center + knob, knobRadius, knobPaint);
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) {
    return oldDelegate.knob != knob || oldDelegate.pressed != pressed;
  }
}

class DPadCross extends StatelessWidget {
  final double size;
  final String value;
  final ValueChanged<String> onChange;

  const DPadCross({
    super.key,
    required this.size,
    required this.value,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    // ABXYCluster의 디자인 기준(기존에 맞춘 값)
    const designSize = 150.0;
    const designBtn = 58.0;
    const designInset = 1.0;

    final k = size / designSize;

    final btn = designBtn * k;       // 버튼 지름도 size에 비례
    final inset = designInset * k;   // 경계 여백도 비례

    // 중앙에서 각 방향으로 이동할 거리(버튼이 안 잘리도록)
    final offset = (size / 2) - (btn / 2) - inset;

    Widget b(String label, String dir) {
      return HoldButton(
        label: label,
        pressed: value == dir,
        width: btn,
        height: btn,
        onPressedChange: (p) => onChange(p ? dir : 'CENTER'),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.translate(offset: Offset(0, -offset), child: b('↑', 'UP')),
          Transform.translate(offset: Offset(0,  offset), child: b('↓', 'DOWN')),
          Transform.translate(offset: Offset(-offset, 0), child: b('←', 'LEFT')),
          Transform.translate(offset: Offset( offset, 0), child: b('→', 'RIGHT')),
        ],
      ),
    );
  }
}
