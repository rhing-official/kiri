#!/usr/bin/env python3
"""PC を BLE キーボード（HID over GATT）に見せかけて iPad にキーを送る試作。

使い方:
    python3 tools/ble_keyboard.py
    → iPad の 設定 > Bluetooth に「kiri-kbd」が出るのでタップしてペアリング。
    → 接続後、標準入力に次のコマンドを打つ:
        right / left / shot / release / q
      (shot = Cmd+Shift+3 のスクリーンショット)

BlueZ の GATT サーバ + LE アドバタイズで実装している。依存は dbus-python と PyGObject。
"""
import sys

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

BLUEZ = 'org.bluez'
ADAPTER_PATH = '/org/bluez/hci0'
DBUS_OM = 'org.freedesktop.DBus.ObjectManager'
DBUS_PROP = 'org.freedesktop.DBus.Properties'
GATT_MANAGER = 'org.bluez.GattManager1'
GATT_SERVICE = 'org.bluez.GattService1'
GATT_CHRC = 'org.bluez.GattCharacteristic1'
GATT_DESC = 'org.bluez.GattDescriptor1'
ADV_MANAGER = 'org.bluez.LEAdvertisingManager1'
ADV_IFACE = 'org.bluez.LEAdvertisement1'
AGENT_MANAGER = 'org.bluez.AgentManager1'
AGENT_IFACE = 'org.bluez.Agent1'

DEVICE_NAME = 'kiri-kbd'

# HID レポートディスクリプタ（修飾キー1B + 予約1B + キー6B の標準キーボード入力のみ）
REPORT_MAP = [
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7,
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07,
    0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0,
]

MOD_SHIFT = 0x02
MOD_GUI = 0x08  # Cmd
KEY_3 = 0x20
KEY_RIGHT = 0x4F
KEY_LEFT = 0x50


def _bytes(data):
    return dbus.Array([dbus.Byte(b) for b in data], signature='y')


class Application(dbus.service.Object):
    def __init__(self, bus):
        self.path = '/'
        self.services = []
        super().__init__(bus, self.path)

    def add(self, service):
        self.services.append(service)

    @dbus.service.method(DBUS_OM, out_signature='a{oa{sa{sv}}}')
    def GetManagedObjects(self):
        out = {}
        for s in self.services:
            out[s.path] = s.props()
            for c in s.chrcs:
                out[c.path] = c.props()
                for d in c.descs:
                    out[d.path] = d.props()
        return out


class Service(dbus.service.Object):
    def __init__(self, bus, index, uuid):
        self.path = f'/org/kiri/service{index}'
        self.uuid = uuid
        self.chrcs = []
        super().__init__(bus, self.path)

    def props(self):
        return {GATT_SERVICE: {
            'UUID': self.uuid,
            'Primary': True,
            'Characteristics': dbus.Array([c.path for c in self.chrcs], signature='o'),
        }}

    @dbus.service.method(DBUS_PROP, in_signature='s', out_signature='a{sv}')
    def GetAll(self, iface):
        return self.props()[GATT_SERVICE]


class Characteristic(dbus.service.Object):
    def __init__(self, bus, index, uuid, flags, service, value=None):
        self.path = f'{service.path}/char{index}'
        self.uuid = uuid
        self.flags = flags
        self.service = service
        self.value = value or []
        self.descs = []
        super().__init__(bus, self.path)
        service.chrcs.append(self)

    def props(self):
        return {GATT_CHRC: {
            'Service': dbus.ObjectPath(self.service.path),
            'UUID': self.uuid,
            'Flags': dbus.Array(self.flags, signature='s'),
            'Descriptors': dbus.Array([d.path for d in self.descs], signature='o'),
        }}

    @dbus.service.method(DBUS_PROP, in_signature='s', out_signature='a{sv}')
    def GetAll(self, iface):
        return self.props()[GATT_CHRC]

    @dbus.service.method(GATT_CHRC, in_signature='a{sv}', out_signature='ay')
    def ReadValue(self, options):
        return _bytes(self.value)

    @dbus.service.method(GATT_CHRC, in_signature='aya{sv}')
    def WriteValue(self, value, options):
        self.value = list(value)

    @dbus.service.method(GATT_CHRC)
    def StartNotify(self):
        pass

    @dbus.service.method(GATT_CHRC)
    def StopNotify(self):
        pass


class Descriptor(dbus.service.Object):
    def __init__(self, bus, index, uuid, flags, chrc, value):
        self.path = f'{chrc.path}/desc{index}'
        self.uuid = uuid
        self.flags = flags
        self.chrc = chrc
        self.value = value
        super().__init__(bus, self.path)
        chrc.descs.append(self)

    def props(self):
        return {GATT_DESC: {
            'Characteristic': dbus.ObjectPath(self.chrc.path),
            'UUID': self.uuid,
            'Flags': dbus.Array(self.flags, signature='s'),
        }}

    @dbus.service.method(DBUS_PROP, in_signature='s', out_signature='a{sv}')
    def GetAll(self, iface):
        return self.props()[GATT_DESC]

    @dbus.service.method(GATT_DESC, in_signature='a{sv}', out_signature='ay')
    def ReadValue(self, options):
        return _bytes(self.value)


class ReportCharacteristic(Characteristic):
    """入力レポート。購読(notify)されたら送信できる。"""

    def __init__(self, bus, index, service, on_subscribe):
        super().__init__(bus, index, '2a4d', ['read', 'notify', 'encrypt-read'],
                         service, [0] * 8)
        self.notifying = False
        self.on_subscribe = on_subscribe

    @dbus.service.method(GATT_CHRC)
    def StartNotify(self):
        self.notifying = True
        self.on_subscribe(True)

    @dbus.service.method(GATT_CHRC)
    def StopNotify(self):
        self.notifying = False
        self.on_subscribe(False)

    @dbus.service.signal(DBUS_PROP, signature='sa{sv}as')
    def PropertiesChanged(self, iface, changed, invalidated):
        pass

    def send(self, report):
        self.value = report
        self.PropertiesChanged(GATT_CHRC, {'Value': _bytes(report)}, [])


class Advertisement(dbus.service.Object):
    def __init__(self, bus):
        self.path = '/org/kiri/advertisement0'
        super().__init__(bus, self.path)

    def props(self):
        return {ADV_IFACE: {
            'Type': 'peripheral',
            'ServiceUUIDs': dbus.Array(['1812'], signature='s'),
            'LocalName': DEVICE_NAME,
            'Appearance': dbus.UInt16(0x03C1),  # Keyboard
        }}

    @dbus.service.method(DBUS_PROP, in_signature='s', out_signature='a{sv}')
    def GetAll(self, iface):
        return self.props()[ADV_IFACE]

    @dbus.service.method(ADV_IFACE)
    def Release(self):
        print('アドバタイズ終了')


class Agent(dbus.service.Object):
    """表示も入力も無い端末として、確認なしでペアリングを受け入れる(Just Works)。"""

    @dbus.service.method(AGENT_IFACE)
    def Release(self):
        pass

    @dbus.service.method(AGENT_IFACE, in_signature='os')
    def AuthorizeService(self, device, uuid):
        return

    @dbus.service.method(AGENT_IFACE, in_signature='o')
    def RequestAuthorization(self, device):
        return

    @dbus.service.method(AGENT_IFACE, in_signature='ouq')
    def DisplayPasskey(self, device, passkey, entered):
        print(f'passkey: {passkey:06d}')

    @dbus.service.method(AGENT_IFACE, in_signature='ou')
    def RequestConfirmation(self, device, passkey):
        print(f'ペアリング確認: {passkey:06d}')
        return

    @dbus.service.method(AGENT_IFACE)
    def Cancel(self):
        pass


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    adapter = bus.get_object(BLUEZ, ADAPTER_PATH)
    adapter_props = dbus.Interface(adapter, DBUS_PROP)
    adapter_props.Set('org.bluez.Adapter1', 'Powered', dbus.Boolean(True))
    adapter_props.Set('org.bluez.Adapter1', 'Pairable', dbus.Boolean(True))
    adapter_props.Set('org.bluez.Adapter1', 'Alias', DEVICE_NAME)

    loop = GLib.MainLoop()

    # --- GATT: HID / Device Information / Battery ---
    app = Application(bus)

    hid = Service(bus, 0, '1812')
    Characteristic(bus, 0, '2a4a', ['read', 'encrypt-read'], hid, [0x11, 0x01, 0x00, 0x02])  # HID Information
    Characteristic(bus, 1, '2a4b', ['read', 'encrypt-read'], hid, REPORT_MAP)
    Characteristic(bus, 2, '2a4c', ['write-without-response'], hid)  # HID Control Point
    Characteristic(bus, 3, '2a4e', ['read', 'write-without-response'], hid, [0x01])  # Protocol Mode = Report
    state = {'subscribed': False}

    def on_subscribe(on):
        state['subscribed'] = on
        print('iPad が接続しました。コマンド: right / left / shot / release / q' if on
              else '購読が解除されました')

    report = ReportCharacteristic(bus, 4, hid, on_subscribe)
    Descriptor(bus, 0, '2908', ['read'], report, [0x00, 0x01])  # Report Reference: id=0, input
    app.add(hid)

    dis = Service(bus, 1, '180a')
    Characteristic(bus, 0, '2a50', ['read'], dis, [0x02, 0x6B, 0x1D, 0x46, 0x02, 0x37, 0x05])  # PnP ID
    Characteristic(bus, 1, '2a29', ['read'], dis, list(b'kiri'))
    app.add(dis)

    bat = Service(bus, 2, '180f')
    Characteristic(bus, 0, '2a19', ['read'], bat, [100])
    app.add(bat)

    # --- キー送信 ---
    def release():
        report.send([0] * 8)

    def press(modifier, keycode):
        if not state['subscribed']:
            print('まだ iPad が接続していません')
            return
        # 押す → キーだけ離す → 修飾キーも離す → 念のため全部離す、の順に段階的に送る
        report.send([modifier, 0, keycode, 0, 0, 0, 0, 0])
        GLib.timeout_add(50, lambda: report.send([modifier, 0, 0, 0, 0, 0, 0, 0]) or False)
        GLib.timeout_add(100, lambda: release() or False)
        GLib.timeout_add(200, lambda: release() or False)

    commands = {
        'right': lambda: press(0, KEY_RIGHT),
        'left': lambda: press(0, KEY_LEFT),
        'shot': lambda: press(MOD_GUI | MOD_SHIFT, KEY_3),
        'release': release,
    }

    def on_stdin(fd, cond):
        line = sys.stdin.readline()
        if not line or line.strip() == 'q':
            loop.quit()
            return False
        cmd = commands.get(line.strip())
        if cmd:
            cmd()
        elif line.strip():
            print('コマンド: right / left / shot / release / q')
        return True

    GLib.io_add_watch(sys.stdin, GLib.IO_IN, on_stdin)

    # --- 登録 ---
    agent = Agent(bus, '/org/kiri/agent')
    agent_mgr = dbus.Interface(bus.get_object(BLUEZ, '/org/bluez'), AGENT_MANAGER)
    agent_mgr.RegisterAgent('/org/kiri/agent', 'NoInputNoOutput')
    agent_mgr.RequestDefaultAgent('/org/kiri/agent')

    def fail(what):
        def handler(err):
            print(f'{what}の登録に失敗: {err}')
            loop.quit()
        return handler

    gatt_mgr = dbus.Interface(adapter, GATT_MANAGER)
    gatt_mgr.RegisterApplication(
        app.path, {},
        reply_handler=lambda: print('GATT 登録完了'),
        error_handler=fail('GATT'))

    adv = Advertisement(bus)
    adv_mgr = dbus.Interface(adapter, ADV_MANAGER)
    adv_mgr.RegisterAdvertisement(
        adv.path, {},
        reply_handler=lambda: print(f'アドバタイズ開始。iPad の設定 > Bluetooth で「{DEVICE_NAME}」をタップ'),
        error_handler=fail('アドバタイズ'))

    try:
        loop.run()
    finally:
        try:
            adv_mgr.UnregisterAdvertisement(adv.path)
            gatt_mgr.UnregisterApplication(app.path)
            agent_mgr.UnregisterAgent('/org/kiri/agent')
        except dbus.DBusException:
            pass


if __name__ == '__main__':
    main()
