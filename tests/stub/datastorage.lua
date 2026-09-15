-- Test stub for KOReader's datastorage module.
return {
  getSettingsDir = function()
    return os.getenv("SM20_STUB_SETTINGS_DIR") or "/tmp/sm20_stub_settings"
  end,
}
