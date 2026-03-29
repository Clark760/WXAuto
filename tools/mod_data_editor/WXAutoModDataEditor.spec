# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['C:\\Users\\Administrator\\Desktop\\WXAuto\\tools\\mod_data_editor\\server.py'],
    pathex=[],
    binaries=[],
    datas=[('C:\\Users\\Administrator\\Desktop\\WXAuto\\tools\\mod_data_editor\\index.html', 'mod_data_editor_static'), ('C:\\Users\\Administrator\\Desktop\\WXAuto\\tools\\mod_data_editor\\styles.css', 'mod_data_editor_static'), ('C:\\Users\\Administrator\\Desktop\\WXAuto\\tools\\mod_data_editor\\app.js', 'mod_data_editor_static')],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='WXAutoModDataEditor',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='WXAutoModDataEditor',
)
