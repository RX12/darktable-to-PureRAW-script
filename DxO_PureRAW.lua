--[[

    DxO_PureRAW.lua - process RAW images in darktable 5.6 with DxO PureRAW 6

    Copyright (C) 2024 Fiona Boston <fiona@fbphotography.uk>
    Updated 2026 for darktable 5.6 (Lua API 9.7.0) and DxO PureRAW 6.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

    ============================================================================

    Overview:
    Adds a lighttable panel to send selected camera RAW files from darktable 5.6
    to DxO PureRAW 6, watch a dedicated staging folder for the processed outputs
    (DNG / TIFF / JPEG), move completed files next to the source RAWs, and
    import them into the same darktable film roll with optional grouping, tag
    copying, metadata copying, and extra tags.

    Required PureRAW 6 configuration (in-app):
    1. Output Format: Standard linear DNG (uncompressed) or TIFF/JPEG.
       IMPORTANT: Do NOT use PureRAW 6's "High-Fidelity compressed DNG"
       (DNG 1.7 / JPEG XL) — darktable 5.6 cannot read JPEG XL-compressed DNGs.
    2. Destination: Custom folder set to the exact same Staging Folder configured
       in darktable Preferences -> Lua Options.
    3. Export to application: None (darktable imports the files automatically).

]]

local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local dsys = require "lib/dtutils.system"

du.check_min_api_version("7.0.0", "DxO_PureRAW")

local gettext = dt.gettext

local MODULE_NAME = "module_DxO_PureRAW"
local LIB_ID = "DxO_pureRAW_Lib"
local IS_WINDOWS = (dt.configuration.running_os == "windows")
local IS_MACOS = (dt.configuration.running_os == "macos")
local PATH_SEP = IS_WINDOWS and "\\" or "/"

-- Polling and command-line batching constants
local POLL_INTERVAL_SEC = 10
local MAX_CMD_LINE_LEN = 7000 -- safely below the Windows 8191-char limit

-- Locate locale directory if present
local script_info = debug.getinfo(1, "S")
local locale_dir = dt.configuration.config_dir .. PATH_SEP .. "lua" .. PATH_SEP .. "locale"
if script_info and script_info.source then
    local dir_prefix = script_info.source:match("^@(.+[/\\])")
    if dir_prefix then
        locale_dir = dir_prefix .. "locale"
    end
end
gettext.bindtextdomain("DxO_pureRAW", locale_dir)

local function _(msgid)
    return gettext.dgettext("dxo_pureraw", msgid)
end

local script_data = {
    metadata = {
        name = "DxO_PureRAW",
        purpose = _("process RAW images with DxO PureRAW 6"),
        author = "Fiona Boston <fiona@fbphotography.uk>",
        help = "https://github.com/fjb2020/darktable-scripts",
    },
    destroy = nil,
    destroy_method = "hide",
    restart = nil,
    show = nil,
}

-- Supported input camera RAW extensions (uppercase keys, matched case-insensitively)
local RAW_FILE_TYPES = {
    DNG = true,
    CR2 = true,
    CR3 = true,
    CRW = true,
    NEF = true,
    NRW = true,
    ARW = true,
    SR2 = true,
    SRF = true,
    RAF = true,
    ORF = true,
    ORI = true,
    RW2 = true,
    RAW = true,
    PEF = true,
    RWL = true,
    ["3FR"] = true,
    FFF = true,
    IIQ = true,
    X3F = true,
    SRW = true,
    DCR = true,
    KDC = true,
    ERF = true,
    MEF = true,
    GPR = true,
}

-- Supported output image extensions produced by PureRAW
local OUTPUT_FILE_TYPES = {
    dng = 1,  -- priority 1 for group leader selection
    tif = 2,
    tiff = 2,
    jpg = 3,
    jpeg = 3,
}

local METADATA_FIELDS = { "title", "description", "creator", "publisher", "rights" }

-- Runtime state
local active_job = nil
local cancel_pressed = false
local is_running = false
local module_state = {
    event_registered = false,
    module_installed = false,
}

local GUI = {
    optionwidgets = {},
    options = nil,
    run = nil,
    cancel = nil,
    btnbox = nil,
}

-- ============================================================================
-- Helper functions
-- ============================================================================

local function log_info(msg)
    dt.print_log("[DxO_PureRAW] " .. tostring(msg))
end

local function log_error(msg)
    dt.print_error("[DxO_PureRAW] " .. tostring(msg))
    dt.print_log("[DxO_PureRAW ERROR] " .. tostring(msg))
end

local function notify_error(user_msg, detail_msg)
    dt.print(user_msg)
    log_error(detail_msg or user_msg)
end

local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Normalize a filesystem path read from preferences: strip outer quotes and trailing slashes
local function clean_path(p)
    p = trim(p)
    p = p:gsub('^["\']+', ""):gsub('["\']+$', "")
    if #p > 1 then
        p = p:gsub("[/\\]+$", "")
    end
    return p
end

-- Double-quote a path for shell invocation
local function quote_arg(p)
    return '"' .. tostring(p) .. '"'
end

-- Ignore OS metadata / hidden files in the staging directory
local function is_ignored_staging_entry(name)
    if not name or name == "" or name == "." or name == ".." then
        return true
    end
    if name:sub(1, 1) == "." then
        return true
    end
    local lower = name:lower()
    if lower == "thumbs.db" or lower == "desktop.ini" then
        return true
    end
    return false
end

-- List entries in a directory without requiring LuaFileSystem
local function list_dir(dir_path)
    local cmd
    if IS_WINDOWS then
        cmd = 'dir "' .. dir_path .. '" /b'
    else
        cmd = 'ls -1a "' .. dir_path .. '"'
    end

    local handle = io.popen(cmd)
    if not handle then
        return nil, "io.popen failed for command: " .. cmd
    end

    local entries = {}
    for line in handle:lines() do
        local entry = line:gsub("\r$", "")
        if not is_ignored_staging_entry(entry) then
            table.insert(entries, entry)
        end
    end
    handle:close()
    return entries
end

-- Return file size in bytes (0 if missing, empty, or locked by writer)
local function get_file_size(filepath)
    local f = io.open(filepath, "rb")
    if not f then
        return 0
    end
    local size = f:seek("end") or 0
    f:close()
    return size
end

-- Move file with fallback to copy + remove (handles cross-volume moves on Windows)
local function move_file_safe(src_path, dst_path)
    if df.file_move(src_path, dst_path) and df.check_if_file_exists(dst_path) then
        return true
    end
    if df.file_copy and df.file_copy(src_path, dst_path) and df.check_if_file_exists(dst_path) then
        os.remove(src_path)
        return true
    end
    return false
end

-- Close active darktable background job safely
local function close_job()
    if active_job and active_job.valid then
        active_job.valid = false
    end
    active_job = nil
end

-- Callback invoked when user clicks the X button on darktable's background job progress bar
local function on_job_cancel(job)
    log_info("Cancel requested via background job progress bar.")
    cancel_pressed = true
    if job and job.valid then
        job.valid = false
    end
end

-- Sleep in 1-second slices so cancellation responds within ~1 second
local function sleep_interruptible(seconds)
    local ticks = math.max(1, math.floor(seconds))
    for _ = 1, ticks do
        if cancel_pressed or (active_job and not active_job.valid) then
            cancel_pressed = true
            return false
        end
        dt.control.sleep(1000)
    end
    if cancel_pressed or (active_job and not active_job.valid) then
        cancel_pressed = true
        return false
    end
    return true
end

-- ============================================================================
-- Preferences & Configuration Validation
-- ============================================================================

local function save_panel_preferences()
    dt.preferences.write(MODULE_NAME, "prefs_saved", "bool", true)
    dt.preferences.write(MODULE_NAME, "group", "bool", GUI.optionwidgets.group.value)
    dt.preferences.write(MODULE_NAME, "copy_tags", "bool", GUI.optionwidgets.copy_tags.value)
    dt.preferences.write(MODULE_NAME, "copy_metadata", "bool", GUI.optionwidgets.copy_metadata.value)
    dt.preferences.write(MODULE_NAME, "add_tags", "string", GUI.optionwidgets.add_tags.text or "")
end

local function load_panel_preferences()
    if dt.preferences.read(MODULE_NAME, "prefs_saved", "bool") then
        GUI.optionwidgets.group.value = dt.preferences.read(MODULE_NAME, "group", "bool")
        GUI.optionwidgets.copy_tags.value = dt.preferences.read(MODULE_NAME, "copy_tags", "bool")
        GUI.optionwidgets.copy_metadata.value = dt.preferences.read(MODULE_NAME, "copy_metadata", "bool")
        GUI.optionwidgets.add_tags.text = dt.preferences.read(MODULE_NAME, "add_tags", "string") or ""
    end
end

-- Validate executable, staging folder, and timeout preferences before starting
local function validate_config()
    local exe_pref = clean_path(dt.preferences.read(MODULE_NAME, "DxO_pureRAWExe", "file"))
    local staging_dir = clean_path(dt.preferences.read(MODULE_NAME, "DxOStagingFolder", "directory"))
    local timeout_mins = tonumber(dt.preferences.read(MODULE_NAME, "DxOTimeout", "integer"))

    -- Fallback in case DxOTimeout was stored as a string in an older darktablerc
    if not timeout_mins then
        timeout_mins = tonumber(dt.preferences.read(MODULE_NAME, "DxOTimeout", "string")) or 2
    end

    -- 1. Validate executable path
    if exe_pref == "" then
        notify_error(
            _("DxO PureRAW executable is not configured. Please set it in Preferences -> Lua Options."),
            "DxO_pureRAWExe preference is empty."
        )
        return nil
    end

    local resolved_exe = exe_pref
    local mac_app_bundle = nil

    if IS_MACOS then
        -- Accept "/Applications/DxO PureRAW 6.app", "/Applications/DxO PureRAW 6",
        -- or an inner binary "/Applications/DxO PureRAW 6.app/Contents/MacOS/..."
        local bundle_from_inner = resolved_exe:match("^(.+%.app)/Contents/MacOS/")
        if bundle_from_inner then
            mac_app_bundle = bundle_from_inner
        elseif resolved_exe:match("%.app$") then
            mac_app_bundle = resolved_exe
        elseif df.check_if_file_exists(resolved_exe .. ".app") then
            resolved_exe = resolved_exe .. ".app"
            mac_app_bundle = resolved_exe
        end
    end

    if not df.check_if_file_exists(resolved_exe) then
        notify_error(
            _("Cannot find DxO PureRAW executable: ") .. resolved_exe .. _(" — please check Preferences -> Lua Options."),
            "Configured executable does not exist: " .. resolved_exe
        )
        return nil
    end

    -- 2. Validate staging folder exists and is empty
    if staging_dir == "" or staging_dir == "5" then
        notify_error(
            _("DxO staging folder is not configured. Please set it in Preferences -> Lua Options."),
            "DxOStagingFolder preference is unset or invalid ('" .. tostring(staging_dir) .. "')."
        )
        return nil
    end

    if not df.check_if_file_exists(staging_dir) then
        notify_error(
            _("Cannot find DxO staging folder: ") .. staging_dir .. _(" — please check Preferences -> Lua Options."),
            "Staging folder does not exist: " .. staging_dir
        )
        return nil
    end

    local existing_files, list_err = list_dir(staging_dir)
    if not existing_files then
        notify_error(
            _("Cannot read DxO staging folder: ") .. staging_dir,
            "Failed to list staging folder '" .. staging_dir .. "': " .. tostring(list_err)
        )
        return nil
    end

    if #existing_files > 0 then
        notify_error(
            _("DxO staging folder is not empty (") .. tostring(#existing_files) .. _(" file(s) found, e.g. ")
                .. existing_files[1] .. _("). Please clear ") .. staging_dir .. _(" before running."),
            "Staging folder not empty (" .. tostring(#existing_files) .. " files in " .. staging_dir .. "; first: " .. existing_files[1] .. ")."
        )
        return nil
    end

    -- 3. Validate per-image timeout
    if timeout_mins <= 0 or timeout_mins > 30 then
        notify_error(
            _("Invalid DxO timeout (") .. tostring(timeout_mins) .. _(" min). Allowed range is 1 to 30 minutes in Lua Options."),
            "Invalid DxOTimeout value: " .. tostring(timeout_mins)
        )
        return nil
    end

    return {
        exe_path = resolved_exe,
        mac_app_bundle = mac_app_bundle,
        staging_dir = staging_dir,
        timeout_sec = timeout_mins * 60,
        timeout_mins = timeout_mins,
    }
end

-- ============================================================================
-- Selection Filtering & Batch Launching
-- ============================================================================

-- Filter lighttable selection to existing camera RAW files
local function collect_valid_sources(selection)
    local sources = {}
    local skipped_non_raw = 0
    local skipped_missing = 0
    local skipped_dxo_dng = 0

    for _, img in ipairs(selection) do
        local full_path = img.path .. PATH_SEP .. img.filename
        local ext_upper = string.upper(df.get_filetype(img.filename) or "")
        local stem = df.get_basename(img.filename)

        if not df.check_if_file_exists(full_path) then
            skipped_missing = skipped_missing + 1
            log_error("Selected file does not exist on disk: " .. full_path)
        elseif not RAW_FILE_TYPES[ext_upper] then
            skipped_non_raw = skipped_non_raw + 1
            log_info("Skipping unsupported non-RAW file: " .. full_path .. " (ext: " .. ext_upper .. ")")
        elseif ext_upper == "DNG" and (stem:find("%-DxO_") or stem:find("_DxO_")) then
            -- PureRAW rejects already-demosaiced linear DNG outputs as input
            skipped_dxo_dng = skipped_dxo_dng + 1
            log_info("Skipping already-processed DxO linear DNG: " .. full_path)
        else
            table.insert(sources, {
                image = img,
                full_path = full_path,
                stem = stem,
                stem_lower = string.lower(stem),
            })
        end
    end

    return sources, skipped_non_raw, skipped_missing, skipped_dxo_dng
end

-- Build command-line batches respecting the Windows ~8k command-line length limit
local function build_launch_batches(config, sources)
    local prefix
    if IS_MACOS then
        if config.mac_app_bundle then
            prefix = "open -a " .. quote_arg(config.mac_app_bundle)
        else
            prefix = quote_arg(config.exe_path)
        end
    elseif IS_WINDOWS then
        prefix = 'start "DxO PureRAW 6" ' .. quote_arg(config.exe_path)
    else
        prefix = quote_arg(config.exe_path)
    end

    local batches = {}
    local current_args = {}
    local current_len = #prefix

    for _, src in ipairs(sources) do
        local qpath = quote_arg(src.full_path)
        if #current_args > 0 and (current_len + 1 + #qpath > MAX_CMD_LINE_LEN) then
            table.insert(batches, prefix .. " " .. table.concat(current_args, " "))
            current_args = { qpath }
            current_len = #prefix + 1 + #qpath
        else
            table.insert(current_args, qpath)
            current_len = current_len + 1 + #qpath
        end
    end

    if #current_args > 0 then
        table.insert(batches, prefix .. " " .. table.concat(current_args, " "))
    end

    return batches
end

-- Launch PureRAW non-blocking across one or more argument batches
local function launch_pureraw(config, sources)
    local batches = build_launch_batches(config, sources)
    log_info("Launching DxO PureRAW with " .. tostring(#sources) .. " image(s) in " .. tostring(#batches) .. " batch(es).")

    for idx, cmd in ipairs(batches) do
        log_info("Executing batch " .. idx .. "/" .. #batches .. ": " .. cmd)
        local resp
        if IS_WINDOWS then
            resp = dsys.windows_command(cmd)
        else
            resp = dsys.external_command(cmd)
        end

        if resp ~= 0 then
            notify_error(
                _("Failed to launch DxO PureRAW (exit code ") .. tostring(resp) .. _("). Please check the executable path in Lua Options."),
                "Command failed with exit code " .. tostring(resp) .. ": " .. cmd
            )
            return false
        end

        if idx < #batches then
            dt.control.sleep(1500)
        end
    end

    return true
end

-- ============================================================================
-- Staging Directory Watcher & Stem Matcher
-- ============================================================================

-- Match a candidate filename in the staging folder to a source RAW.
-- Supports PureRAW suffixes (e.g. "IMG_0001-DxO_DeepPRIME XD3.dng"),
-- prefixes (e.g. "20261004-20261004_0104.dng"), prefix+suffix combinations,
-- and duplicate counters ("_01"). Disambiguates overlapping stems (e.g. IMG_1 vs IMG_10)
-- using token boundaries and longest stem length.
local function match_candidate_to_source(filename, sources)
    local ext_lower = string.lower(df.get_filetype(filename) or "")
    if not OUTPUT_FILE_TYPES[ext_lower] then
        return nil
    end

    local cand_stem_lower = string.lower(df.get_basename(filename) or "")
    if cand_stem_lower == "" then
        return nil
    end

    local best_src = nil
    local best_len = 0
    local best_boundary = false

    for _, src in ipairs(sources) do
        local slen = #src.stem_lower
        if slen > 0 then
            local start_pos = 1
            while start_pos <= #cand_stem_lower do
                local s, e = cand_stem_lower:find(src.stem_lower, start_pos, true)
                if not s then
                    break
                end

                local prev_ch = (s > 1) and cand_stem_lower:sub(s - 1, s - 1) or ""
                local next_ch = (e < #cand_stem_lower) and cand_stem_lower:sub(e + 1, e + 1) or ""
                local on_boundary = (prev_ch == "" or not prev_ch:match("%d"))
                    and (next_ch == "" or not next_ch:match("%d"))

                if (on_boundary and not best_boundary)
                    or (on_boundary == best_boundary and slen > best_len)
                then
                    best_src = src
                    best_len = slen
                    best_boundary = on_boundary
                end

                start_pos = s + 1
            end
        end
    end

    -- Fallback: if only 1 image was sent and PureRAW used a custom rename without the original stem
    if not best_src and #sources == 1 then
        best_src = sources[1]
    end

    return best_src
end

-- Remove any files left in the staging folder on user cancellation
local function cleanup_staging_files(staging_dir, initial_snapshot)
    local entries = list_dir(staging_dir) or {}
    for _, fname in ipairs(entries) do
        if not initial_snapshot[fname] then
            local full_path = staging_dir .. PATH_SEP .. fname
            log_info("Cleaning up staged file after cancel: " .. full_path)
            os.remove(full_path)
        end
    end
end

-- Poll the staging folder until every source image has at least one size-stable output
-- (and no unstable outputs currently writing), or timeout / cancel occurs.
local function wait_for_pureraw_outputs(config, sources, initial_snapshot)
    local total_sources = #sources
    -- file_state[filename] = { size = <bytes>, stable = <bool>, src = <source> }
    local file_state = {}
    local completed_sources = 0
    local last_progress_time = os.time()
    local start_time = os.time()

    active_job = dt.gui.create_job(
        _("Waiting for DxO PureRAW 6 (0 of ") .. tostring(total_sources) .. _(" ready)..."),
        true,
        on_job_cancel
    )

    dt.print(
        _("Sent ") .. tostring(total_sources) .. _(" image(s) to DxO PureRAW. Start processing in PureRAW; darktable is watching ")
        .. config.staging_dir
    )

    while true do
        if not sleep_interruptible(POLL_INTERVAL_SEC) then
            close_job()
            cleanup_staging_files(config.staging_dir, initial_snapshot)
            dt.print(_("DxO PureRAW wait cancelled."))
            log_info("Wait cancelled by user.")
            return nil, "cancelled"
        end

        local entries, err = list_dir(config.staging_dir)
        if not entries then
            log_error("Error polling staging folder: " .. tostring(err))
            entries = {}
        end

        -- Track which files currently exist in staging
        local present_now = {}
        for _, fname in ipairs(entries) do
            if not initial_snapshot[fname] then
                local src = match_candidate_to_source(fname, sources)
                if src then
                    present_now[fname] = true
                    local full_path = config.staging_dir .. PATH_SEP .. fname
                    local current_size = get_file_size(full_path)
                    local st = file_state[fname]

                    if not st then
                        file_state[fname] = {
                            size = current_size,
                            stable = false,
                            src = src,
                        }
                        log_info(
                            "Detected new candidate in staging: " .. fname
                            .. " (" .. tostring(current_size) .. " bytes, matched source: " .. src.image.filename .. ")"
                        )
                    else
                        if current_size > 0 and current_size == st.size then
                            if not st.stable then
                                log_info("Candidate size-stable across two polls: " .. fname .. " (" .. tostring(current_size) .. " bytes)")
                            end
                            st.stable = true
                        else
                            st.size = current_size
                            st.stable = false
                        end
                    end
                end
            end
        end

        -- Prune state for any file that disappeared from staging
        for fname, _ in pairs(file_state) do
            if not present_now[fname] then
                file_state[fname] = nil
            end
        end

        -- Evaluate per-source readiness:
        -- A source is ready when it has >= 1 stable file and 0 unstable files in staging.
        local new_completed_count = 0
        local any_unstable = false

        for _, src in ipairs(sources) do
            local stable_count = 0
            local unstable_count = 0
            for _, st in pairs(file_state) do
                if st.src == src then
                    if st.stable then
                        stable_count = stable_count + 1
                    else
                        unstable_count = unstable_count + 1
                        any_unstable = true
                    end
                end
            end
            if stable_count > 0 and unstable_count == 0 then
                new_completed_count = new_completed_count + 1
            end
        end

        if new_completed_count > completed_sources then
            completed_sources = new_completed_count
            last_progress_time = os.time()
            log_info("Progress: " .. tostring(completed_sources) .. " of " .. tostring(total_sources) .. " source image(s) ready.")
        end

        if active_job and active_job.valid then
            active_job.percent = math.min(0.99, completed_sources / total_sources)
        end

        if completed_sources >= total_sources and not any_unstable then
            log_info("All " .. tostring(total_sources) .. " source image(s) finished in " .. tostring(os.difftime(os.time(), start_time)) .. "s.")
            break
        end

        local idle_sec = os.difftime(os.time(), last_progress_time)
        if idle_sec >= config.timeout_sec then
            log_error(
                "Timed out after " .. tostring(config.timeout_mins) .. " minute(s) without progress ("
                .. tostring(completed_sources) .. " of " .. tostring(total_sources) .. " ready)."
            )
            close_job()
            return file_state, "timeout"
        end
    end

    close_job()
    return file_state, "ok"
end

-- ============================================================================
-- Move & Import Results into darktable
-- ============================================================================

local function apply_import_options(imported_img, raw_img, make_leader)
    -- 1. Copy tags (skipping internal "darktable|" tags)
    if GUI.optionwidgets.copy_tags.value then
        local raw_tags = dt.tags.get_tags(raw_img)
        for _, tag in ipairs(raw_tags) do
            if not tag.name:match("^darktable|") then
                dt.tags.attach(tag, imported_img)
            end
        end
    end

    -- 2. Attach user-specified comma-separated tags
    local extra_tags = GUI.optionwidgets.add_tags.text
    if extra_tags and extra_tags ~= "" then
        for raw_tag in string.gmatch(extra_tags, "[^,]+") do
            local tag_name = trim(raw_tag)
            if tag_name ~= "" then
                local tag_obj = dt.tags.create(tag_name)
                if tag_obj then
                    dt.tags.attach(tag_obj, imported_img)
                end
            end
        end
    end

    -- 3. Copy metadata fields (including publisher in darktable 5.6)
    if GUI.optionwidgets.copy_metadata.value then
        for _, field in ipairs(METADATA_FIELDS) do
            local val = raw_img[field]
            if val and val ~= "" then
                imported_img[field] = val
            end
        end
    end

    -- 4. Group with original RAW and optionally make leader
    if GUI.optionwidgets.group.value then
        imported_img:group_with(raw_img)
        if make_leader then
            imported_img:make_group_leader()
        end
    end
end

local function import_ready_outputs(config, sources, file_state)
    -- Collect stable files per source image, sorted so primary formats (DNG/TIFF) come last
    -- and therefore become the group leader when multiple formats (e.g. DNG + JPG) are imported.
    local total_imported = 0
    local import_failures = 0
    local hf_dng_failures = 0

    active_job = dt.gui.create_job(_("Importing DxO PureRAW results..."), true, nil)

    for idx, src in ipairs(sources) do
        local ready_files = {}
        for fname, st in pairs(file_state) do
            if st.src == src and st.stable then
                table.insert(ready_files, fname)
            end
        end

        table.sort(ready_files, function(a, b)
            local ext_a = string.lower(df.get_filetype(a) or "")
            local ext_b = string.lower(df.get_filetype(b) or "")
            local prio_a = OUTPUT_FILE_TYPES[ext_a] or 99
            local prio_b = OUTPUT_FILE_TYPES[ext_b] or 99
            if prio_a ~= prio_b then
                return prio_a > prio_b -- import secondary formats (JPG) first, primary (DNG) last
            end
            return a < b
        end)

        for f_idx, fname in ipairs(ready_files) do
            local staged_path = config.staging_dir .. PATH_SEP .. fname
            if df.check_if_file_exists(staged_path) then
                local desired_target = src.image.path .. PATH_SEP .. fname
                local target_path = df.create_unique_filename(desired_target)

                if not target_path or target_path == "" then
                    import_failures = import_failures + 1
                    notify_error(
                        _("Could not create unique target filename for ") .. fname,
                        "df.create_unique_filename returned empty for: " .. desired_target
                    )
                elseif not move_file_safe(staged_path, target_path) then
                    import_failures = import_failures + 1
                    notify_error(
                        _("Failed to move ") .. fname .. _(" into ") .. src.image.path,
                        "Failed moving '" .. staged_path .. "' -> '" .. target_path .. "'"
                    )
                else
                    log_info("Moved '" .. staged_path .. "' -> '" .. target_path .. "'")
                    local imported_img = dt.database.import(target_path)

                    if imported_img == nil then
                        import_failures = import_failures + 1
                        local ext_lower = string.lower(df.get_filetype(target_path) or "")
                        if ext_lower == "dng" then
                            hf_dng_failures = hf_dng_failures + 1
                            notify_error(
                                _("Failed to import ") .. df.get_filename(target_path)
                                    .. _(" — darktable cannot read PureRAW 6 'High-Fidelity compressed DNG' (DNG 1.7 / JPEG XL). ")
                                    .. _("Please set PureRAW 6 Output Format to standard linear 'DNG' (uncompressed) or 'TIFF'."),
                                "dt.database.import returned nil for existing DNG: " .. target_path
                                    .. " (likely DxO PureRAW 6 High-Fidelity JPEG XL compressed DNG 1.7)."
                            )
                        else
                            notify_error(
                                _("Failed to import ") .. df.get_filename(target_path) .. _(" into darktable."),
                                "dt.database.import returned nil for: " .. target_path
                            )
                        end
                    else
                        total_imported = total_imported + 1
                        local is_leader = (f_idx == #ready_files)
                        apply_import_options(imported_img, src.image, is_leader)
                        log_info("Imported into darktable: " .. imported_img.path .. PATH_SEP .. imported_img.filename)
                    end
                end
            end
        end

        if active_job and active_job.valid then
            active_job.percent = idx / #sources
        end
    end

    close_job()
    return total_imported, import_failures, hf_dng_failures
end

-- ============================================================================
-- Main Workflow Entry Points
-- ============================================================================

local function set_running_state(running)
    is_running = running
    if GUI.run then
        GUI.run.sensitive = not running
    end
    if GUI.cancel then
        GUI.cancel.sensitive = running
    end
end

local function start_processing()
    if is_running then
        dt.print(_("DxO PureRAW is already running — press 'Cancel Waiting' to abort."))
        return
    end

    save_panel_preferences()
    cancel_pressed = false

    local selection = dt.gui.selection()
    if #selection < 1 then
        dt.print(_("Please select at least one RAW image in the lighttable."))
        return
    end

    -- 1. Validate executable, staging folder, and timeout
    local config = validate_config()
    if not config then
        return
    end

    -- 2. Filter selection to valid camera RAWs
    local sources, skipped_non_raw, skipped_missing, skipped_dxo_dng = collect_valid_sources(selection)
    if #sources < 1 then
        if skipped_dxo_dng > 0 then
            notify_error(
                _("Selected DNG(s) appear to be already-processed DxO linear DNGs, which PureRAW cannot re-process."),
                "All selected images were skipped (dxo_dng=" .. skipped_dxo_dng .. ", non_raw=" .. skipped_non_raw .. ", missing=" .. skipped_missing .. ")."
            )
        elseif skipped_non_raw > 0 then
            notify_error(
                _("No supported camera RAW images selected (") .. tostring(skipped_non_raw) .. _(" non-RAW file(s) skipped)."),
                "No valid RAW images in selection (non_raw=" .. skipped_non_raw .. ", missing=" .. skipped_missing .. ")."
            )
        else
            notify_error(
                _("No valid RAW files found on disk for the current selection."),
                "All selected files were missing on disk (missing=" .. skipped_missing .. ")."
            )
        end
        return
    end

    if skipped_non_raw > 0 or skipped_dxo_dng > 0 or skipped_missing > 0 then
        dt.print(
            _("Sending ") .. tostring(#sources) .. _(" RAW image(s) to DxO PureRAW (skipped ")
            .. tostring(skipped_non_raw + skipped_dxo_dng + skipped_missing) .. _(" unsupported/missing file(s)).")
        )
    end

    -- 3. Snapshot staging directory before launching PureRAW
    local initial_snapshot = {}
    for _, entry in ipairs(list_dir(config.staging_dir) or {}) do
        initial_snapshot[entry] = true
    end

    set_running_state(true)
    local ok, err = pcall(function()
        -- 4. Launch PureRAW (chunked into command-line batches if needed)
        if not launch_pureraw(config, sources) then
            return
        end

        -- 5. Poll staging folder for completed outputs
        local file_state, status = wait_for_pureraw_outputs(config, sources, initial_snapshot)
        if not file_state or status == "cancelled" then
            return
        end

        -- 6. Move and import completed files into the source film roll(s)
        local imported_count, failed_count, hf_dng_count = import_ready_outputs(config, sources, file_state)

        if status == "timeout" then
            if imported_count > 0 then
                dt.print(
                    _("DxO PureRAW timed out: imported ") .. tostring(imported_count)
                    .. _(" file(s) before timeout (check Lua log for details).")
                )
            else
                notify_error(
                    _("Timed out waiting for DxO PureRAW output in ") .. config.staging_dir
                    .. _(" — verify PureRAW's destination folder matches the staging folder in Lua Options."),
                    "Timeout waiting for outputs in " .. config.staging_dir .. " (0 files imported)."
                )
            end
        elseif hf_dng_count > 0 then
            -- Detailed HF-DNG toast was already shown by import_ready_outputs
            log_error("Completed with " .. tostring(hf_dng_count) .. " High-Fidelity compressed DNG import failure(s).")
        elseif failed_count > 0 then
            dt.print(
                _("Imported ") .. tostring(imported_count) .. _(" file(s) from DxO PureRAW (")
                .. tostring(failed_count) .. _(" failed — see Lua log).")
            )
        else
            dt.print(_("Successfully imported ") .. tostring(imported_count) .. _(" file(s) from DxO PureRAW."))
        end
    end)

    close_job()
    set_running_state(false)

    if not ok then
        notify_error(
            _("DxO PureRAW script error — see Lua log for details."),
            "Unhandled runtime error: " .. tostring(err)
        )
    end
end

local function cancel_processing()
    if not is_running then
        dt.print(_("No DxO PureRAW job is currently running."))
        return
    end
    log_info("Cancel button clicked in DxO PureRAW panel.")
    cancel_pressed = true
    close_job()
end

-- ============================================================================
-- GUI & Preferences Registration
-- ============================================================================

GUI.optionwidgets.label_import_options = dt.new_widget("section_label") {
    label = _("import options"),
}

GUI.optionwidgets.group = dt.new_widget("check_button") {
    label = _("group with original"),
    value = true,
    tooltip = _("Group processed image(s) with the original RAW and make the processed image group leader"),
    reset_callback = function(self)
        self.value = true
    end,
}

GUI.optionwidgets.copy_tags = dt.new_widget("check_button") {
    label = _("copy existing tags"),
    value = true,
    tooltip = _("Copy tags from the source RAW image (skipping internal darktable| tags) to the imported image(s)"),
    reset_callback = function(self)
        self.value = true
    end,
}

GUI.optionwidgets.copy_metadata = dt.new_widget("check_button") {
    label = _("copy metadata"),
    value = true,
    tooltip = _("Copy metadata (title, description, creator, publisher, rights) to the imported image(s)"),
    reset_callback = function(self)
        self.value = true
    end,
}

GUI.optionwidgets.add_tags_label = dt.new_widget("label") {
    label = _("extra tags"),
    ellipsize = "start",
    halign = "start",
}

GUI.optionwidgets.add_tags = dt.new_widget("entry") {
    tooltip = _("Additional comma-separated tags to attach on import"),
    placeholder = _("Enter tags, separated by commas"),
    editable = true,
}

GUI.optionwidgets.add_tags_box = dt.new_widget("box") {
    orientation = "horizontal",
    GUI.optionwidgets.add_tags_label,
    GUI.optionwidgets.add_tags,
}

GUI.options = dt.new_widget("box") {
    orientation = "vertical",
    GUI.optionwidgets.label_import_options,
    GUI.optionwidgets.group,
    GUI.optionwidgets.copy_tags,
    GUI.optionwidgets.copy_metadata,
    GUI.optionwidgets.add_tags_box,
}

GUI.run = dt.new_widget("button") {
    label = _("Process with DxO PureRAW"),
    tooltip = _(
        "Send selected RAW image(s) to DxO PureRAW 6 and import results from the staging folder. "
        .. "In PureRAW 6, set Output Format to standard linear DNG (not High-Fidelity compressed DNG) "
        .. "and Destination to the configured staging folder."
    ),
    clicked_callback = function()
        start_processing()
    end,
}

GUI.cancel = dt.new_widget("button") {
    label = _("Cancel Waiting"),
    tooltip = _("Cancel waiting for DxO PureRAW and clean up the background job"),
    sensitive = false,
    clicked_callback = function()
        cancel_processing()
    end,
}

GUI.btnbox = dt.new_widget("box") {
    orientation = "horizontal",
    GUI.run,
    GUI.cancel,
}

local default_exe_path = ""
if IS_WINDOWS then
    default_exe_path = "C:\\Program Files\\DxO\\DxO PureRAW 6\\PureRawv6.exe"
elseif IS_MACOS then
    default_exe_path = "/Applications/DxO PureRAW 6.app"
end

dt.preferences.register(
    MODULE_NAME,
    "DxOTimeout",
    "integer",
    _("DxO PureRAW timeout per image (mins)"),
    _("Maximum time in minutes (1 - 30) to wait per image for DxO PureRAW 6 processing"),
    2,
    1,
    30,
    1
)

dt.preferences.register(
    MODULE_NAME,
    "DxOStagingFolder",
    "directory",
    _("DxO PureRAW staging folder"),
    _(
        "Dedicated empty staging folder where DxO PureRAW 6 writes processed files before darktable moves them "
        .. "next to the source RAWs. Must match PureRAW's configured output destination folder."
    ),
    ""
)

dt.preferences.register(
    MODULE_NAME,
    "DxO_pureRAWExe",
    "file",
    _("DxO PureRAW 6 executable"),
    _(
        "Path to DxO PureRAW 6 (Windows: C:\\Program Files\\DxO\\DxO PureRAW 6\\PureRawv6.exe; "
        .. "macOS: /Applications/DxO PureRAW 6.app)"
    ),
    default_exe_path
)

load_panel_preferences()

local function install_module()
    if not module_state.module_installed then
        dt.register_lib(
            LIB_ID,
            _("DxO PureRAW"),
            true,
            true,
            { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 99 } },
            dt.new_widget("box") {
                orientation = "vertical",
                GUI.options,
                GUI.btnbox,
            },
            nil,
            nil
        )
        module_state.module_installed = true
    end
end

local function destroy()
    if dt.gui.libs[LIB_ID] then
        dt.gui.libs[LIB_ID].visible = false
    end
end

local function restart()
    if dt.gui.libs[LIB_ID] then
        dt.gui.libs[LIB_ID].visible = true
    end
end

if dt.gui.current_view().id == "lighttable" then
    install_module()
else
    if not module_state.event_registered then
        dt.register_event(
            "DxO_PureRAW",
            "view-changed",
            function(_, _, new_view)
                if new_view.id == "lighttable" then
                    install_module()
                end
            end
        )
        module_state.event_registered = true
    end
end

script_data.destroy = destroy
script_data.restart = restart
script_data.destroy_method = "hide"
script_data.show = restart

return script_data
