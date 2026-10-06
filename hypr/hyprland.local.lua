-- Personal Hyprland settings, loaded after Hyprkarl's modules, the active
-- theme, and the display layout, so anything here wins. Hyprkarl creates this
-- file once and never replaces it. Hyprkarl's own modules under
-- $HYPRKARL_PATH/defaults/hypr/ show the syntax.
--
-- To split this file up, require your own files from ~/.config/hypr/; give
-- them names that differ from Hyprkarl's modules (envs, bindings, input, ...).
--
-- hl.config({ input = { kb_layout = "us,fi" } })
--
-- hl.unbind("SUPER + RETURN")
-- hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("uwsm-app -- my-terminal"), {
--     description = "Terminal",
-- })

-- Tap, then hold the second tap, to drag
hl.config({ input = { touchpad = { tap_and_drag = true } } })

-- Locked groups get a transparent border
hl.config({
    group = {
        col = {
            border_locked_active = "rgba(00000000)",
            border_locked_inactive = "rgba(00000000)",
        },
    },
})

-- SUPER + CTRL + SPACE is left free: it is Wispr Flow's hands-free shortcut
-- Pause or resume the mic mute switch starting Wispr hands-free (hk-wispr-switch)
hl.bind("SUPER + ALT + D", hl.dsp.exec_cmd("hk-wispr-switch toggle"), { description = "Toggle Wispr mic switch" })

hl.on("hyprland.start", function()
    -- Secret Service for apps that keep passwords in the keyring
    hl.exec_cmd("/usr/bin/gnome-keyring-daemon --start --components=secrets")

    -- Mic mute switch -> Wispr hands-free. Before Wispr: its helper only
    -- finds keyboards (this one's virtual keyboard) when it starts.
    hl.exec_cmd("uwsm app -- hk-wispr-switch")

    -- Wispr Flow in the tray (the hk-app launcher adds the accessibility flag
    -- that hk-wispr-word-add needs)
    hl.exec_cmd("uwsm app -- ~/.local/bin/wispr-flow --hidden")
end)
