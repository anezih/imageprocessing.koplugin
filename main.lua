local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local DocCache = require("document/doccache")
local Document = require("document/document")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local RenderImage = require("ui/renderimage")
local SpinWidget = require("ui/widget/spinwidget")
local TileCacheItem = require("document/tilecacheitem")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local util = require("ffi/util")
local T = util.template
local android = ffi.os == "Linux" and os.getenv("IS_ANDROID") and require("android") or nil

ffi.cdef[[
typedef struct ImageProcessingBlitBuffer {
    unsigned int w;
    unsigned int pixel_stride;
    unsigned int h;
    size_t stride;
    uint8_t *data;
    uint8_t config;
} ImageProcessingBlitBuffer;

int koreader_imageprocessing_blitbuffer(
    const ImageProcessingBlitBuffer *src,
    ImageProcessingBlitBuffer *dst,
    int algorithm,
    int sharpen_level,
    int darken_level,
    int auto_color_level,
    int contrast_level,
    int hue_shift,
    int saturation_level,
    int brightness_level
);

const char *koreader_imageprocessing_version(void);
]]

local ImageProcessing = WidgetContainer:extend{
    name = "imageprocessing",
    is_doc_only = true,
}

local SETTINGS_PREFIX = "imageprocessing_koplugin_"
local SETTING_ENABLED = SETTINGS_PREFIX .. "enabled"
local SETTING_ALGORITHM = SETTINGS_PREFIX .. "algorithm"
local SETTING_SHARPENING = SETTINGS_PREFIX .. "sharpening"
local SETTING_TEXT_DARKENING = SETTINGS_PREFIX .. "text_darkening"
local SETTING_AUTO_COLOR = SETTINGS_PREFIX .. "auto_color"
local SETTING_CONTRAST = SETTINGS_PREFIX .. "contrast"
local SETTING_HUE = SETTINGS_PREFIX .. "hue"
local SETTING_SATURATION = SETTINGS_PREFIX .. "saturation"
local SETTING_BRIGHTNESS = SETTINGS_PREFIX .. "brightness"
local SETTING_SHOW_BOTTOM_CONFIG = SETTINGS_PREFIX .. "show_bottom_config"
local CONFIG_ENABLED = "imageprocessing_enabled"
local CONFIG_ALGORITHM = "imageprocessing_algorithm"
local CONFIG_SHARPENING = "imageprocessing_sharpening"
local CONFIG_TEXT_DARKENING = "imageprocessing_text_darkening"
local CONFIG_AUTO_COLOR = "imageprocessing_auto_color"
local CONFIG_CONTRAST = "imageprocessing_contrast"
local CONFIG_HUE = "imageprocessing_hue"
local CONFIG_SATURATION = "imageprocessing_saturation"
local CONFIG_BRIGHTNESS = "imageprocessing_brightness"
local CONFIG_SCALING_ICON = "imageprocessing.scale"
local CONFIG_COLOR_ICON = "imageprocessing.color"
local CONFIG_SCALING_FALLBACK_ICON = "appbar.pokeball"
local CONFIG_COLOR_FALLBACK_ICON = "texture-box"
local DEFAULT_ENABLED = true
local DEFAULT_ALGORITHM = "lanczos2"
local DEFAULT_SHARPENING = 1
local DEFAULT_TEXT_DARKENING = 1
local DEFAULT_AUTO_COLOR = 0
local DEFAULT_CONTRAST = 0
local DEFAULT_HUE = 0
local DEFAULT_SATURATION = 0
local DEFAULT_BRIGHTNESS = 0
local DEFAULT_SHOW_BOTTOM_CONFIG = true

local algorithms = {
    { id = "lanczos2", label = _("Lanczos 2"), native_id = 0 },
    { id = "lanczos3", label = _("Lanczos 3"), native_id = 1 },
    { id = "avir", label = _("AVIR default"), native_id = 2 },
    { id = "avir_low_ringing", label = _("AVIR low ringing"), native_id = 3 },
    { id = "avir_ultra_low_ringing", label = _("AVIR ultra-low ringing"), native_id = 4 },
    { id = "avir_low_aliasing", label = _("AVIR low aliasing"), native_id = 5 },
    { id = "avir_ultra_low_aliasing", label = _("AVIR ultra-low aliasing"), native_id = 6 },
    { id = "mupdf", label = _("KOReader default"), native_id = nil },
}

local algorithm_by_id = {}
for _, algorithm in ipairs(algorithms) do
    algorithm_by_id[algorithm.id] = algorithm
end

local enhancement_levels = {
    { id = 0, label = _("Off") },
    { id = 1, label = _("Low") },
    { id = 2, label = _("Medium") },
    { id = 3, label = _("High") },
}

local enhancement_by_id = {}
for _, level in ipairs(enhancement_levels) do
    enhancement_by_id[level.id] = level
end

local adjustment_levels = {
    { id = -2, label = _("Much lower") },
    { id = -1, label = _("Lower") },
    { id = 0, label = _("Normal") },
    { id = 1, label = _("Low") },
    { id = 2, label = _("Medium") },
    { id = 3, label = _("High") },
}

local adjustment_by_id = {}
for _, level in ipairs(adjustment_levels) do
    adjustment_by_id[level.id] = level
end

local hue_levels = {
    { id = -30, label = _("-30 deg") },
    { id = -15, label = _("-15 deg") },
    { id = 0, label = _("Normal") },
    { id = 15, label = _("+15 deg") },
    { id = 30, label = _("+30 deg") },
}

local hue_by_id = {}
for _, level in ipairs(hue_levels) do
    hue_by_id[level.id] = level
end

local algorithm_help = {
    lanczos2 = _("Balanced Lanczos scaling. Good default for manga pages: smooth edges with modest ringing."),
    lanczos3 = _("Sharper Lanczos scaling. It can preserve fine line detail better, but may add more ringing around hard edges."),
    avir = _("AVIR's default profile. A balanced high-quality scaler with a sharper look than the low-ringing profiles."),
    avir_low_ringing = _("Reduces halos and ringing around text and panel borders. It may look slightly softer."),
    avir_ultra_low_ringing = _("Minimizes ringing as much as possible. Useful for harsh high-contrast pages, but usually softer."),
    avir_low_aliasing = _("Prioritizes anti-aliasing when downscaling. Useful when fine patterns shimmer or break up."),
    avir_ultra_low_aliasing = _("Strong anti-aliasing profile. More expensive and may look smoother or slightly less crisp."),
    mupdf = _("Uses KOReader's default scaling path instead of the plugin's native AVIR/Lanczos path."),
}

local sharpening_help = {
    [0] = _("No sharpening is applied after scaling."),
    [1] = _("Light sharpening. Recommended default: improves text and line edges without much haloing."),
    [2] = _("Medium sharpening. More visible edge crispness, with some risk of halos on high-contrast art."),
    [3] = _("Strong sharpening. Best for testing; may make text bolder but can introduce artifacts."),
}

local text_darkening_help = {
    [0] = _("No text darkening is applied after scaling."),
    [1] = _("Light darkening. Recommended default: makes gray anti-aliased strokes denser while mostly preserving whites."),
    [2] = _("Medium darkening. Text and panel lines become more assertive, but light gray tones may darken."),
    [3] = _("Strong darkening. Useful for faint scans; may crush shadow detail or make art too heavy."),
}

local auto_color_help = {
    [0] = _("No automatic color correction is applied."),
    [1] = _("Mildly expands the image tonal range when scans look washed out."),
    [2] = _("Expands the tonal range more strongly. Useful for faded color pages."),
    [3] = _("Strong correction. Useful for testing; may exaggerate colors or paper tint."),
}

local contrast_help = {
    [-2] = _("Strongly lowers contrast."),
    [-1] = _("Slightly lowers contrast."),
    [0] = _("Leaves contrast unchanged."),
    [1] = _("Mild contrast boost."),
    [2] = _("Medium contrast boost."),
    [3] = _("Strong contrast boost. May crush shadows or highlights."),
}

local saturation_help = {
    [-2] = _("Strongly reduces color saturation."),
    [-1] = _("Slightly reduces color saturation."),
    [0] = _("Leaves color saturation unchanged."),
    [1] = _("Mild saturation boost."),
    [2] = _("Medium saturation boost."),
    [3] = _("Strong saturation boost. May make colors look unnatural."),
}

local brightness_help = {
    [-2] = _("Strongly darkens the image."),
    [-1] = _("Slightly darkens the image."),
    [0] = _("Leaves brightness unchanged."),
    [1] = _("Slightly brightens the image."),
    [2] = _("Brightens the image."),
    [3] = _("Strongly brightens the image. May wash out highlights."),
}

local hue_help = {
    [-30] = _("Shifts color hue 30 degrees backward."),
    [-15] = _("Shifts color hue 15 degrees backward."),
    [0] = _("Leaves hue unchanged."),
    [15] = _("Shifts color hue 15 degrees forward."),
    [30] = _("Shifts color hue 30 degrees forward."),
}

local original_scale_blitbuffer
local original_document_render_page
local native_lib
local native_load_attempted
local plugin_path = "./plugins/imageprocessing.koplugin"
local active_plugin
local render_generation = 0
local CUSTOM_ENHANCEMENT_MAX = 100
local config_scaling_icon = CONFIG_SCALING_ICON
local config_color_icon = CONFIG_COLOR_ICON
local config_option_names = {
    CONFIG_ENABLED,
    CONFIG_ALGORITHM,
    CONFIG_SHARPENING,
    CONFIG_TEXT_DARKENING,
    CONFIG_AUTO_COLOR,
    CONFIG_CONTRAST,
    CONFIG_HUE,
    CONFIG_SATURATION,
    CONFIG_BRIGHTNESS,
}

local LiveSpinWidget = SpinWidget:extend{}

function LiveSpinWidget:update(numberpicker_value, numberpicker_value_index)
    local previous_value = self.value_widget and self.value_widget:getValue() or nil
    SpinWidget.update(self, numberpicker_value, numberpicker_value_index)
    local current_value = self.value_widget and self.value_widget:getValue() or nil
    if self.live_callback and self._live_spin_initialized
        and previous_value ~= nil and current_value ~= nil
        and previous_value ~= current_value then
        self.live_callback(self, current_value)
    end
    self._live_spin_initialized = true
end

local function fileExists(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file"
end

local function filesDiffer(source_path, target_path)
    local src_attr = lfs.attributes(source_path)
    local dst_attr = lfs.attributes(target_path)
    if not src_attr or not dst_attr then
        return true
    end
    if dst_attr.size ~= src_attr.size or dst_attr.modification ~= src_attr.modification then
        return true
    end

    local src_hash = util.partialMD5(source_path)
    local dst_hash = util.partialMD5(target_path)
    if not src_hash or not dst_hash then
        return true
    end
    return src_hash ~= dst_hash
end

local function ensureDir(path)
    local current = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        if part ~= "." then
            if current == "" or current == "/" then
                current = current .. part
            else
                current = current .. "/" .. part
            end
            lfs.mkdir(current)
        end
    end
end

local function getAndroidAbiDir()
    if not android or not android.nativeLibraryDir then
        return nil
    end
    if android.nativeLibraryDir:find("/arm64") then
        return "arm64-v8a"
    end
    if android.nativeLibraryDir:find("/arm") then
        return "armeabi-v7a"
    end
    return nil
end

local function copyFile(source_path, target_path)
    local input = io.open(source_path, "rb")
    if not input then
        return false
    end
    local data = input:read("*a")
    input:close()

    local output = io.open(target_path, "wb")
    if not output then
        return false
    end
    output:write(data)
    output:close()
    return true
end

local function copyConfigIconToDir(icon_name, target_dir)
    local source_path = plugin_path .. "/resources/icons/" .. icon_name .. ".svg"
    if not fileExists(source_path) then
        return false
    end
    local target_path = target_dir .. "/" .. icon_name .. ".svg"
    ensureDir(target_dir)
    if filesDiffer(source_path, target_path) then
        if not copyFile(source_path, target_path) then
            return false
        end
    end
    return fileExists(target_path)
end

local function installConfigIcon(icon_name)
    copyConfigIconToDir(icon_name, DataStorage:getDataDir() .. "/icons")
    return copyConfigIconToDir(icon_name, "./resources/icons")
end

local function installConfigIcons()
    config_scaling_icon = installConfigIcon(CONFIG_SCALING_ICON)
        and CONFIG_SCALING_ICON or CONFIG_SCALING_FALLBACK_ICON
    config_color_icon = installConfigIcon(CONFIG_COLOR_ICON)
        and CONFIG_COLOR_ICON or CONFIG_COLOR_FALLBACK_ICON
end

local function stageAndroidLibrary(source_path)
    local abi_dir = getAndroidAbiDir()
    if not abi_dir or not fileExists(source_path) then
        return nil
    end

    local target_dir = android.dir .. "/plugins/imageprocessing.koplugin/libs/android/" .. abi_dir
    local target_path = target_dir .. "/libimageprocessing.so"
    ensureDir(target_dir)

    if not fileExists(target_path) or filesDiffer(source_path, target_path) then
        local err = util.copyFile(source_path, target_path)
        if err then
            logger.warn("ImageProcessing: failed to stage Android library", err)
            return nil
        end
    end

    return target_path
end

local function loadNative()
    if native_load_attempted then
        return native_lib
    end
    native_load_attempted = true

    local candidates
    if android then
        local abi_dir = getAndroidAbiDir()
        local staged = abi_dir and stageAndroidLibrary(plugin_path .. "/libs/android/" .. abi_dir .. "/libimageprocessing.so")
        candidates = {
            "imageprocessing",
            staged,
        }
    else
        candidates = {
            "imageprocessing",
            plugin_path .. "/libs/libimageprocessing.so",
            plugin_path .. "/libs/linux/x86_64/libimageprocessing.so",
            plugin_path .. "/libs/android/armeabi-v7a/libimageprocessing.so",
            plugin_path .. "/libs/android/arm64-v8a/libimageprocessing.so",
            plugin_path .. "/libs/kobo/kobov5/libimageprocessing.so",
            plugin_path .. "/libs/kindle/kindlehf/libimageprocessing.so",
            plugin_path .. "/libs/kindle/kindlepw2/libimageprocessing.so",
            plugin_path .. "/libs/kindle/kindle/libimageprocessing.so",
            plugin_path .. "/libs/kindle/kindle-legacy/libimageprocessing.so",
            plugin_path .. "/libs/pocketbook/pocketbook/libimageprocessing.so",
        }
    end

    for _, name in ipairs(candidates) do
        if name then
            local ok, lib = pcall(ffi.load, name)
            if ok and lib then
                native_lib = lib
                logger.info("ImageProcessing: loaded native library", name)
                return native_lib
            end
        end
    end

    logger.warn("ImageProcessing: native library not found; falling back to KOReader default")
    return nil
end

local function getNativeFunction(lib, name)
    local ok, func = pcall(function()
        return lib[name]
    end)
    if ok then
        return func
    end
    return nil
end

local function isEnabled()
    return G_reader_settings:readSetting(SETTING_ENABLED, DEFAULT_ENABLED)
end

local function setEnabled(enabled)
    G_reader_settings:saveSetting(SETTING_ENABLED, enabled)
end

local function showBottomConfig()
    return G_reader_settings:readSetting(SETTING_SHOW_BOTTOM_CONFIG, DEFAULT_SHOW_BOTTOM_CONFIG)
end

local function setShowBottomConfig(show)
    G_reader_settings:saveSetting(SETTING_SHOW_BOTTOM_CONFIG, show)
end

local function getAlgorithm()
    local id = G_reader_settings:readSetting(SETTING_ALGORITHM, DEFAULT_ALGORITHM)
    return algorithm_by_id[id] or algorithm_by_id[DEFAULT_ALGORITHM]
end

local function clampNumber(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function formatCustomEnhancementLabel(value)
    return _("Custom") .. " (" .. tostring(value) .. ")"
end

local function getCustomEnhancementSettingName(setting_name)
    return setting_name .. "_custom"
end

local function getEnhancementValue(setting_name, default_id)
    local id = G_reader_settings:readSetting(setting_name, default_id)
    id = tonumber(id) or default_id
    id = math.floor(id)
    return clampNumber(id, 0, CUSTOM_ENHANCEMENT_MAX)
end

local function getStoredCustomEnhancementValue(setting_name, default_id)
    local custom_setting_name = getCustomEnhancementSettingName(setting_name)
    local id = G_reader_settings:readSetting(custom_setting_name)
    if id == nil then
        local active_id = getEnhancementValue(setting_name, default_id)
        if not enhancement_by_id[active_id] then
            return active_id
        end
        return default_id
    end
    id = tonumber(id) or default_id
    id = math.floor(id)
    return clampNumber(id, 0, CUSTOM_ENHANCEMENT_MAX)
end

local function getEnhancementLevel(setting_name, default_id)
    local id = getEnhancementValue(setting_name, default_id)
    return enhancement_by_id[id] or {
        id = id,
        label = formatCustomEnhancementLabel(id),
        is_custom = true,
    }
end

local function getSharpeningLevel()
    return getEnhancementLevel(SETTING_SHARPENING, DEFAULT_SHARPENING)
end

local function getTextDarkeningLevel()
    return getEnhancementLevel(SETTING_TEXT_DARKENING, DEFAULT_TEXT_DARKENING)
end

local function getAdjustmentLevel(setting_name, default_id)
    local id = G_reader_settings:readSetting(setting_name, default_id)
    id = tonumber(id) or default_id
    return adjustment_by_id[id] or adjustment_by_id[default_id]
end

local function getHueLevel()
    local id = G_reader_settings:readSetting(SETTING_HUE, DEFAULT_HUE)
    id = tonumber(id) or DEFAULT_HUE
    return hue_by_id[id] or hue_by_id[DEFAULT_HUE]
end

local function getAutoColorLevel()
    return getEnhancementLevel(SETTING_AUTO_COLOR, DEFAULT_AUTO_COLOR)
end

local function getContrastLevel()
    return getAdjustmentLevel(SETTING_CONTRAST, DEFAULT_CONTRAST)
end

local function getSaturationLevel()
    return getAdjustmentLevel(SETTING_SATURATION, DEFAULT_SATURATION)
end

local function getBrightnessLevel()
    return getAdjustmentLevel(SETTING_BRIGHTNESS, DEFAULT_BRIGHTNESS)
end

local function saveNumericSetting(setting_name, value)
    G_reader_settings:saveSetting(setting_name, value)
end

local function saveCustomEnhancementMemory(setting_name, value)
    G_reader_settings:saveSetting(getCustomEnhancementSettingName(setting_name), value)
end

local function refreshForChangedValue(previous_value, current_value, touchmenu_instance)
    if touchmenu_instance then
        touchmenu_instance:updateItems()
    end
    if active_plugin and active_plugin.ui and previous_value ~= current_value then
        active_plugin:refreshCurrentPage()
    end
end

local function resetSettingsToDefaults()
    G_reader_settings:saveSetting(SETTING_ENABLED, DEFAULT_ENABLED)
    G_reader_settings:saveSetting(SETTING_ALGORITHM, DEFAULT_ALGORITHM)
    G_reader_settings:saveSetting(SETTING_SHARPENING, DEFAULT_SHARPENING)
    G_reader_settings:saveSetting(SETTING_TEXT_DARKENING, DEFAULT_TEXT_DARKENING)
    G_reader_settings:saveSetting(SETTING_AUTO_COLOR, DEFAULT_AUTO_COLOR)
    saveCustomEnhancementMemory(SETTING_SHARPENING, DEFAULT_SHARPENING)
    saveCustomEnhancementMemory(SETTING_TEXT_DARKENING, DEFAULT_TEXT_DARKENING)
    saveCustomEnhancementMemory(SETTING_AUTO_COLOR, DEFAULT_AUTO_COLOR)
    G_reader_settings:saveSetting(SETTING_CONTRAST, DEFAULT_CONTRAST)
    G_reader_settings:saveSetting(SETTING_HUE, DEFAULT_HUE)
    G_reader_settings:saveSetting(SETTING_SATURATION, DEFAULT_SATURATION)
    G_reader_settings:saveSetting(SETTING_BRIGHTNESS, DEFAULT_BRIGHTNESS)
    G_reader_settings:saveSetting(SETTING_SHOW_BOTTOM_CONFIG, DEFAULT_SHOW_BOTTOM_CONFIG)
end

local function isSupportedDocument(doc)
    local suffix = doc and doc.file and doc.file:match("%.([^.]+)$")
    suffix = suffix and suffix:lower()
    return suffix == "cbz" or suffix == "cbr" or suffix == "cbt"
        or suffix == "zip" or suffix == "rar" or suffix == "tar"
        or suffix == "cb7" or suffix == "7z"
        or suffix == "pdf" or suffix == "djvu"
end

local function scaleWithAlgorithm(bb, width, height, algorithm, free_orig_bb)
    if not isEnabled() then
        return original_scale_blitbuffer(RenderImage, bb, width, height, free_orig_bb)
    end

    if not active_plugin or not active_plugin.ui or not active_plugin.ui.document then
        return original_scale_blitbuffer(RenderImage, bb, width, height, free_orig_bb)
    end

    if not width or not height then
        return bb
    end

    width, height = math.floor(width), math.floor(height)
    if bb:getWidth() == width and bb:getHeight() == height then
        return bb
    end

    if bb.getRotation and bb:getRotation() ~= 0 then
        return original_scale_blitbuffer(RenderImage, bb, width, height, free_orig_bb)
    end

    if not algorithm.native_id then
        return original_scale_blitbuffer(RenderImage, bb, width, height, free_orig_bb)
    end

    local lib = loadNative()
    if not lib then
        return original_scale_blitbuffer(RenderImage, bb, width, height, free_orig_bb)
    end

    local scaled_bb = Blitbuffer.new(width, height, bb:getType())
    logger.info("ImageProcessing: scaling", bb:getWidth() .. "x" .. bb:getHeight(), "to",
        width .. "x" .. height, "with", algorithm.id,
        "sharpen", getSharpeningLevel().id,
        "darken", getTextDarkeningLevel().id,
        "auto_color", getAutoColorLevel().id,
        "contrast", getContrastLevel().id,
        "hue", getHueLevel().id,
        "saturation", getSaturationLevel().id,
        "brightness", getBrightnessLevel().id)
    local imageprocessing_func = getNativeFunction(lib, "koreader_imageprocessing_blitbuffer")
    if not imageprocessing_func then
        scaled_bb:free()
        logger.warn("ImageProcessing: native library does not export a supported scaling function")
        return original_scale_blitbuffer(RenderImage, bb, width, height, free_orig_bb)
    end

    local ok, result = pcall(imageprocessing_func,
        ffi.cast("const ImageProcessingBlitBuffer *", bb),
        ffi.cast("ImageProcessingBlitBuffer *", scaled_bb),
        algorithm.native_id,
        getSharpeningLevel().id,
        getTextDarkeningLevel().id,
        getAutoColorLevel().id,
        getContrastLevel().id,
        getHueLevel().id,
        getSaturationLevel().id,
        getBrightnessLevel().id)

    if ok and result == 0 then
        if free_orig_bb ~= false then
            bb:free()
        end
        return scaled_bb
    end

    scaled_bb:free()
    logger.warn("ImageProcessing: native scaling failed for", algorithm.id, "result", result)
    return original_scale_blitbuffer(RenderImage, bb, width, height, free_orig_bb)
end

local function scaleWithNative(bb, width, height, free_orig_bb)
    return scaleWithAlgorithm(bb, width, height, getAlgorithm(), free_orig_bb)
end

local function renderComicPageWithNativeImageProcessing(doc, pageno, rect, zoom, rotation, gamma, hinting)
    local algorithm = getAlgorithm()
    if not isEnabled() or not algorithm.native_id or not isSupportedDocument(doc) or zoom == 1 then
        return original_document_render_page(doc, pageno, rect, zoom, rotation, gamma, hinting)
    end

    local page_size = doc:getPageDimensions(pageno, zoom, rotation)
    local hash = table.concat({
        "imageprocessing",
        tostring(render_generation),
        algorithm.id,
        tostring(getSharpeningLevel().id),
        tostring(getTextDarkeningLevel().id),
        tostring(getAutoColorLevel().id),
        tostring(getContrastLevel().id),
        tostring(getHueLevel().id),
        tostring(getSaturationLevel().id),
        tostring(getBrightnessLevel().id),
        doc.file or "",
        tostring(pageno),
        tostring(zoom),
        tostring(rotation),
        tostring(gamma),
        tostring(page_size.w),
        tostring(page_size.h),
    }, "|")

    local cached = DocCache:check(hash, TileCacheItem)
    if cached then
        return cached
    end

    local source_tile = original_document_render_page(doc, pageno, nil, 1, rotation, gamma, hinting)
    if not source_tile or not source_tile.bb then
        return original_document_render_page(doc, pageno, rect, zoom, rotation, gamma, hinting)
    end

    logger.info("ImageProcessing: comic page", pageno, "native", source_tile.bb:getWidth() .. "x" .. source_tile.bb:getHeight(),
        "target", page_size.w .. "x" .. page_size.h, "with", algorithm.id)
    local scaled_bb = scaleWithNative(source_tile.bb, page_size.w, page_size.h, false)
    if scaled_bb == source_tile.bb then
        return source_tile
    end

    local tile = TileCacheItem:new{
        persistent = false,
        doc_path = doc.file,
        created_ts = os.time(),
        excerpt = Geom:new{ x = 0, y = 0, w = page_size.w, h = page_size.h },
        pageno = pageno,
        bb = scaled_bb,
    }
    tile.size = tonumber(tile.bb.stride) * tile.bb.h + 512
    DocCache:insert(hash, tile)
    return tile
end

function ImageProcessing:refreshCurrentPage()
    render_generation = render_generation + 1

    local ui = self.ui
    local document = ui and ui.document
    DocCache:clear()
    if document and document.resetTileCacheValidity then
        document:resetTileCacheValidity()
    end

    local state = self:getCurrentPageState()
    if ui and state and state.page then
        ui:handleEvent(Event:new("PageUpdate", state.page))
    elseif ui then
        ui:handleEvent(Event:new("UpdatePos"))
        ui:handleEvent(Event:new("RedrawCurrentView"))
    end
    UIManager:setDirty(nil, "partial")
end

local function getAlgorithmMenuItems()
    local items = {}
    for _, algorithm in ipairs(algorithms) do
        table.insert(items, {
            text = algorithm.label,
            checked_func = function()
                return getAlgorithm().id == algorithm.id
            end,
            callback = function(touchmenu_instance)
                local previous_algorithm = getAlgorithm().id
                G_reader_settings:saveSetting(SETTING_ALGORITHM, algorithm.id)
                logger.info("ImageProcessing: selected algorithm", algorithm.id)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
                if active_plugin and active_plugin.ui and previous_algorithm ~= algorithm.id then
                    active_plugin:refreshCurrentPage()
                end
            end,
            help_text = algorithm_help[algorithm.id] or _("Selects the scaling algorithm used for page images."),
            keep_menu_open = true,
        })
    end
    return items
end

local function getEnhancementMenuItems(setting_name, default_id, help_by_id)
    local items = {}
    for _, level in ipairs(enhancement_levels) do
        table.insert(items, {
            text = level.label,
            checked_func = function()
                return getEnhancementValue(setting_name, default_id) == level.id
            end,
            callback = function(touchmenu_instance)
                local previous_level = getEnhancementValue(setting_name, default_id)
                saveNumericSetting(setting_name, level.id)
                logger.info("ImageProcessing: selected enhancement", setting_name, level.id)
                refreshForChangedValue(previous_level, level.id, touchmenu_instance)
            end,
            help_text = help_by_id[level.id] or _("Controls post-processing strength after scaling."),
            keep_menu_open = true,
        })
    end
    table.insert(items, {
        text_func = function()
            local level = getEnhancementLevel(setting_name, default_id)
            return level.is_custom and level.label or _("Custom")
        end,
        checked_func = function()
            return getEnhancementLevel(setting_name, default_id).is_custom == true
        end,
        callback = function(touchmenu_instance)
            local original_active_value = getEnhancementValue(setting_name, default_id)
            local initial_custom_value = getStoredCustomEnhancementValue(setting_name, default_id)
            local function saveCustomValue(value)
                local numeric_value = clampNumber(math.floor(tonumber(value) or initial_custom_value), 0, CUSTOM_ENHANCEMENT_MAX)
                local previous_value = getEnhancementValue(setting_name, default_id)
                if previous_value == numeric_value then
                    saveCustomEnhancementMemory(setting_name, numeric_value)
                    return
                end
                saveCustomEnhancementMemory(setting_name, numeric_value)
                saveNumericSetting(setting_name, numeric_value)
                logger.info("ImageProcessing: selected custom enhancement", setting_name, numeric_value)
                refreshForChangedValue(previous_value, numeric_value, touchmenu_instance)
            end

            UIManager:show(LiveSpinWidget:new{
                title_text = _("Custom value"),
                info_text = _("Sets a precise post-processing strength."),
                value = initial_custom_value,
                value_min = 0,
                value_max = CUSTOM_ENHANCEMENT_MAX,
                value_step = 1,
                value_hold_step = 5,
                cancel_text = _("Revert"),
                ok_text = _("Done"),
                ok_always_enabled = true,
                callback = function(widget)
                    saveCustomValue(widget.value)
                end,
                cancel_callback = function()
                    local current_value = getEnhancementValue(setting_name, default_id)
                    saveNumericSetting(setting_name, original_active_value)
                    refreshForChangedValue(current_value, original_active_value, touchmenu_instance)
                end,
                close_callback = function()
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
                live_callback = function(_, value)
                    saveCustomValue(value)
                end,
            })
        end,
        help_text = _("Opens a numeric control for a precise strength value."),
        keep_menu_open = true,
    })
    return items
end

local function getAdjustmentMenuItems(setting_name, default_id, help_by_id)
    local items = {}
    for _, level in ipairs(adjustment_levels) do
        table.insert(items, {
            text = level.label,
            checked_func = function()
                return getAdjustmentLevel(setting_name, default_id).id == level.id
            end,
            callback = function(touchmenu_instance)
                local previous_level = getAdjustmentLevel(setting_name, default_id).id
                G_reader_settings:saveSetting(setting_name, level.id)
                logger.info("ImageProcessing: selected adjustment", setting_name, level.id)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
                if active_plugin and active_plugin.ui and previous_level ~= level.id then
                    active_plugin:refreshCurrentPage()
                end
            end,
            help_text = help_by_id[level.id] or _("Controls color post-processing strength."),
            keep_menu_open = true,
        })
    end
    return items
end

local function getHueMenuItems()
    local items = {}
    for _, level in ipairs(hue_levels) do
        table.insert(items, {
            text = level.label,
            checked_func = function()
                return getHueLevel().id == level.id
            end,
            callback = function(touchmenu_instance)
                local previous_level = getHueLevel().id
                G_reader_settings:saveSetting(SETTING_HUE, level.id)
                logger.info("ImageProcessing: selected hue", level.id)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
                if active_plugin and active_plugin.ui and previous_level ~= level.id then
                    active_plugin:refreshCurrentPage()
                end
            end,
            help_text = hue_help[level.id] or _("Shifts the image hue."),
            keep_menu_open = true,
        })
    end
    return items
end

local function getConfigAlgorithmLabels()
    return {
        _("L2"),
        _("L3"),
        _("AVIR"),
        _("LR"),
        _("ULR"),
        _("LA"),
        _("ULA"),
        _("KO"),
    }
end

local function getConfigAlgorithmValues()
    local values = {}
    for _, algorithm in ipairs(algorithms) do
        table.insert(values, algorithm.id)
    end
    return values
end

local function getConfigEnhancementValues()
    return { 0, 1, 2, 3 }
end

local function getConfigEnhancementLabels()
    return { _("Off"), _("Low"), _("Med"), _("High") }
end

local function getConfigAdjustmentValues()
    return { -2, -1, 0, 1, 2, 3 }
end

local function getConfigAdjustmentLabels()
    return { _("-2"), _("-1"), _("0"), _("1"), _("2"), _("3") }
end

local function getConfigHueValues()
    return { -30, -15, 0, 15, 30 }
end

local function getConfigHueLabels()
    return { _("-30°"), _("-15°"), _("0°"), _("15°"), _("30°") }
end

local function refreshConfigValue(name, value)
    if active_plugin and active_plugin.ui and active_plugin.ui.document then
        active_plugin.ui.document.configurable[name] = value
    end
end

local function refreshConfigValues()
    refreshConfigValue(CONFIG_ENABLED, isEnabled() and 1 or 0)
    refreshConfigValue(CONFIG_ALGORITHM, getAlgorithm().id)
    refreshConfigValue(CONFIG_SHARPENING, getEnhancementValue(SETTING_SHARPENING, DEFAULT_SHARPENING))
    refreshConfigValue(CONFIG_TEXT_DARKENING, getEnhancementValue(SETTING_TEXT_DARKENING, DEFAULT_TEXT_DARKENING))
    refreshConfigValue(CONFIG_AUTO_COLOR, getEnhancementValue(SETTING_AUTO_COLOR, DEFAULT_AUTO_COLOR))
    refreshConfigValue(CONFIG_CONTRAST, getAdjustmentLevel(SETTING_CONTRAST, DEFAULT_CONTRAST).id)
    refreshConfigValue(CONFIG_HUE, getHueLevel().id)
    refreshConfigValue(CONFIG_SATURATION, getAdjustmentLevel(SETTING_SATURATION, DEFAULT_SATURATION).id)
    refreshConfigValue(CONFIG_BRIGHTNESS, getAdjustmentLevel(SETTING_BRIGHTNESS, DEFAULT_BRIGHTNESS).id)
end

local function updateBottomConfigDialog()
    refreshConfigValues()
    local config_dialog = active_plugin and active_plugin.ui and active_plugin.ui.config
        and active_plugin.ui.config.config_dialog
    if config_dialog then
        config_dialog:update()
        UIManager:setDirty(config_dialog, function()
            return "ui", config_dialog.dialog_frame.dimen
        end)
    end
end

local function onConfigValueChanged(previous_value, current_value)
    updateBottomConfigDialog()
    if active_plugin and active_plugin.ui and previous_value ~= current_value then
        active_plugin:refreshCurrentPage()
    end
    return true
end

local function setConfigEnhancement(setting_name, default_id, value)
    local numeric_value = clampNumber(math.floor(tonumber(value) or default_id), 0, CUSTOM_ENHANCEMENT_MAX)
    local previous_value = getEnhancementValue(setting_name, default_id)
    saveCustomEnhancementMemory(setting_name, numeric_value)
    saveNumericSetting(setting_name, numeric_value)
    logger.info("ImageProcessing: config enhancement", setting_name, numeric_value)
    return onConfigValueChanged(previous_value, numeric_value)
end

local function setConfigAdjustment(setting_name, default_id, value)
    local numeric_value = tonumber(value) or default_id
    local previous_value = getAdjustmentLevel(setting_name, default_id).id
    saveNumericSetting(setting_name, numeric_value)
    logger.info("ImageProcessing: config adjustment", setting_name, numeric_value)
    return onConfigValueChanged(previous_value, numeric_value)
end

local function showConfigHelp(_, option)
    UIManager:show(InfoMessage:new{
        text = option.help_text or option.name_text or _("Image processing"),
    })
end

local function getImageProcessingConfigPanels()
    local enhancement_values = getConfigEnhancementValues()
    local enhancement_labels = getConfigEnhancementLabels()
    local adjustment_values = getConfigAdjustmentValues()
    local adjustment_labels = getConfigAdjustmentLabels()
    local hue_values = getConfigHueValues()
    local hue_labels = getConfigHueLabels()
    return {
        {
            icon = config_scaling_icon,
            options = {
                {
                    name = CONFIG_ENABLED,
                    name_text = _("Image processing"),
                    toggle = { _("off"), _("on") },
                    values = { 0, 1 },
                    args = { 0, 1 },
                    default_value = DEFAULT_ENABLED and 1 or 0,
                    current_func = function()
                        return isEnabled() and 1 or 0
                    end,
                    event = "ImageProcessingSetEnabled",
                    help_text = _("Enables or disables native page image scaling and post-processing."),
                    name_text_hold_callback = showConfigHelp,
                },
                {
                    name = CONFIG_ALGORITHM,
                    name_text = _("Scaler"),
                    toggle = getConfigAlgorithmLabels(),
                    values = getConfigAlgorithmValues(),
                    args = getConfigAlgorithmValues(),
                    default_value = DEFAULT_ALGORITHM,
                    current_func = function()
                        return getAlgorithm().id
                    end,
                    event = "ImageProcessingSetAlgorithm",
                    row_count = 2,
                    height = 60,
                    help_text = _("Selects the scaler used when page images are fitted to the screen."),
                    name_text_hold_callback = showConfigHelp,
                },
                {
                    name = CONFIG_SHARPENING,
                    name_text = _("Sharpen"),
                    buttonprogress = true,
                    values = enhancement_values,
                    args = enhancement_values,
                    labels = enhancement_labels,
                    default_pos = DEFAULT_SHARPENING + 1,
                    default_value = DEFAULT_SHARPENING,
                    current_func = function()
                        return getEnhancementValue(SETTING_SHARPENING, DEFAULT_SHARPENING)
                    end,
                    event = "ImageProcessingSetSharpening",
                    more_options = true,
                    more_options_param = {
                        value_step = 1,
                        value_hold_step = 5,
                        value_min = 0,
                        value_max = CUSTOM_ENHANCEMENT_MAX,
                    },
                    help_text = _("Applies an edge-sharpening pass after scaling."),
                    name_text_hold_callback = showConfigHelp,
                },
                {
                    name = CONFIG_TEXT_DARKENING,
                    name_text = _("Text"),
                    buttonprogress = true,
                    values = enhancement_values,
                    args = enhancement_values,
                    labels = enhancement_labels,
                    default_pos = DEFAULT_TEXT_DARKENING + 1,
                    default_value = DEFAULT_TEXT_DARKENING,
                    current_func = function()
                        return getEnhancementValue(SETTING_TEXT_DARKENING, DEFAULT_TEXT_DARKENING)
                    end,
                    event = "ImageProcessingSetTextDarkening",
                    more_options = true,
                    more_options_param = {
                        value_step = 1,
                        value_hold_step = 5,
                        value_min = 0,
                        value_max = CUSTOM_ENHANCEMENT_MAX,
                    },
                    help_text = _("Darkens darker anti-aliased pixels after scaling."),
                    name_text_hold_callback = showConfigHelp,
                },
            },
        },
        {
            icon = config_color_icon,
            options = {
                {
                    name = CONFIG_AUTO_COLOR,
                    name_text = _("Auto color"),
                    buttonprogress = true,
                    values = enhancement_values,
                    args = enhancement_values,
                    labels = enhancement_labels,
                    default_pos = DEFAULT_AUTO_COLOR + 1,
                    default_value = DEFAULT_AUTO_COLOR,
                    current_func = function()
                        return getEnhancementValue(SETTING_AUTO_COLOR, DEFAULT_AUTO_COLOR)
                    end,
                    event = "ImageProcessingSetAutoColor",
                    more_options = true,
                    more_options_param = {
                        value_step = 1,
                        value_hold_step = 5,
                        value_min = 0,
                        value_max = CUSTOM_ENHANCEMENT_MAX,
                    },
                    help_text = _("Expands weak tonal range after scaling."),
                    name_text_hold_callback = showConfigHelp,
                },
                {
                    name = CONFIG_CONTRAST,
                    name_text = _("Contrast"),
                    buttonprogress = true,
                    values = adjustment_values,
                    args = adjustment_values,
                    labels = adjustment_labels,
                    default_pos = 3,
                    default_value = DEFAULT_CONTRAST,
                    current_func = function()
                        return getAdjustmentLevel(SETTING_CONTRAST, DEFAULT_CONTRAST).id
                    end,
                    event = "ImageProcessingSetContrast",
                    help_text = _("Adjusts contrast after automatic color correction."),
                    name_text_hold_callback = showConfigHelp,
                },
                {
                    name = CONFIG_HUE,
                    name_text = _("Hue"),
                    toggle = hue_labels,
                    values = hue_values,
                    args = hue_values,
                    default_value = DEFAULT_HUE,
                    current_func = function()
                        return getHueLevel().id
                    end,
                    event = "ImageProcessingSetHue",
                    help_text = _("Shifts color hue."),
                    name_text_hold_callback = showConfigHelp,
                },
                {
                    name = CONFIG_SATURATION,
                    name_text = _("Saturation"),
                    buttonprogress = true,
                    values = adjustment_values,
                    args = adjustment_values,
                    labels = adjustment_labels,
                    default_pos = 3,
                    default_value = DEFAULT_SATURATION,
                    current_func = function()
                        return getAdjustmentLevel(SETTING_SATURATION, DEFAULT_SATURATION).id
                    end,
                    event = "ImageProcessingSetSaturation",
                    help_text = _("Adjusts color saturation."),
                    name_text_hold_callback = showConfigHelp,
                },
                {
                    name = CONFIG_BRIGHTNESS,
                    name_text = _("Brightness"),
                    buttonprogress = true,
                    values = adjustment_values,
                    args = adjustment_values,
                    labels = adjustment_labels,
                    default_pos = 3,
                    default_value = DEFAULT_BRIGHTNESS,
                    current_func = function()
                        return getAdjustmentLevel(SETTING_BRIGHTNESS, DEFAULT_BRIGHTNESS).id
                    end,
                    event = "ImageProcessingSetBrightness",
                    help_text = _("Adjusts image brightness after scaling."),
                    name_text_hold_callback = showConfigHelp,
                },
            },
        },
    }
end

local function addToBottomConfigMenu(ui)
    local config = ui and ui.config
    if not config or not config.options or config.options.imageprocessing_added or not showBottomConfig() then
        return
    end
    installConfigIcons()
    for _, panel in ipairs(getImageProcessingConfigPanels()) do
        panel.imageprocessing_panel = true
        table.insert(config.options, panel)
    end
    config.options.imageprocessing_added = true
    refreshConfigValues()
end

local function syncBottomConfigMenu(ui)
    if showBottomConfig() then
        addToBottomConfigMenu(ui)
    end
end

function ImageProcessing:getCurrentPageState()
    local view = self.ui and self.ui.view
    local document = self.ui and self.ui.document
    if not view or not document then
        return nil
    end
    local state = view.state or {}
    local page = state.page
    if not page and document.getCurrentPage then
        page = document:getCurrentPage()
    end
    if not page then
        return nil
    end
    return {
        page = page,
        zoom = state.zoom or 1,
        rotation = state.rotation or 0,
        gamma = state.gamma or document.GAMMA_NO_GAMMA,
    }
end

function ImageProcessing:init()
    active_plugin = self
    plugin_path = self.path or plugin_path
    self:onDispatcherRegisterActions()
    if not original_scale_blitbuffer then
        original_scale_blitbuffer = RenderImage.scaleBlitBuffer
        RenderImage.scaleBlitBuffer = function(render_image, bb, width, height, free_orig_bb)
            return scaleWithNative(bb, width, height, free_orig_bb)
        end
    end
    if not original_document_render_page then
        original_document_render_page = Document.renderPage
        Document.renderPage = renderComicPageWithNativeImageProcessing
    end
    self.ui.menu:registerToMainMenu(self)
    syncBottomConfigMenu(self.ui)
end

function ImageProcessing:onReaderReady()
    syncBottomConfigMenu(self.ui)
end

function ImageProcessing:onDispatcherRegisterActions()
    Dispatcher:registerAction("imageprocessing_enable",
        { category = "string", event = "ToggleImageProcessing", title = _("Image processing"),
          reader = true, args = { true, false }, toggle = { _("enable"), _("disable") }, arg = true })
    Dispatcher:registerAction("imageprocessing_toggle",
        { category = "none", event = "ToggleImageProcessing", title = _("Image processing: toggle"),
          reader = true })
end

function ImageProcessing:onToggleImageProcessing(arg)
    local enabled = arg
    if enabled == nil then
        enabled = not isEnabled()
    end
    setEnabled(enabled)
    logger.info("ImageProcessing: enabled", enabled)
    Notification:notify(
        enabled and _("Image processing enabled") or _("Image processing disabled"),
        Notification.SOURCE_DISPATCHER
    )
    if self.ui then
        self:refreshCurrentPage()
    end
    return true
end

function ImageProcessing:onImageProcessingSetEnabled(value)
    local previous_value = isEnabled() and 1 or 0
    local enabled = value == true or value == 1
    setEnabled(enabled)
    logger.info("ImageProcessing: config enabled", enabled)
    return onConfigValueChanged(previous_value, enabled and 1 or 0)
end

function ImageProcessing:onImageProcessingSetAlgorithm(value)
    if not algorithm_by_id[value] then
        return true
    end
    local previous_value = getAlgorithm().id
    G_reader_settings:saveSetting(SETTING_ALGORITHM, value)
    logger.info("ImageProcessing: config algorithm", value)
    return onConfigValueChanged(previous_value, value)
end

function ImageProcessing:onImageProcessingSetSharpening(value)
    return setConfigEnhancement(SETTING_SHARPENING, DEFAULT_SHARPENING, value)
end

function ImageProcessing:onImageProcessingSetTextDarkening(value)
    return setConfigEnhancement(SETTING_TEXT_DARKENING, DEFAULT_TEXT_DARKENING, value)
end

function ImageProcessing:onImageProcessingSetAutoColor(value)
    return setConfigEnhancement(SETTING_AUTO_COLOR, DEFAULT_AUTO_COLOR, value)
end

function ImageProcessing:onImageProcessingSetContrast(value)
    return setConfigAdjustment(SETTING_CONTRAST, DEFAULT_CONTRAST, value)
end

function ImageProcessing:onImageProcessingSetHue(value)
    local numeric_value = tonumber(value) or DEFAULT_HUE
    local previous_value = getHueLevel().id
    saveNumericSetting(SETTING_HUE, numeric_value)
    logger.info("ImageProcessing: config hue", numeric_value)
    return onConfigValueChanged(previous_value, numeric_value)
end

function ImageProcessing:onImageProcessingSetSaturation(value)
    return setConfigAdjustment(SETTING_SATURATION, DEFAULT_SATURATION, value)
end

function ImageProcessing:onImageProcessingSetBrightness(value)
    return setConfigAdjustment(SETTING_BRIGHTNESS, DEFAULT_BRIGHTNESS, value)
end

function ImageProcessing:onSaveSettings()
    if self.ui and self.ui.doc_settings then
        local prefix = self.ui.config and self.ui.config.options and self.ui.config.options.prefix
        if prefix then
            for _, name in ipairs(config_option_names) do
                self.ui.doc_settings:delSetting(prefix .. "_" .. name)
            end
        end
    end
end

function ImageProcessing:onCloseDocument()
    if active_plugin == self then
        active_plugin = nil
    end
end

local function getImageProcessingMenuItem()
    return {
        text = _("Image processing"),
        help_text = _("Configure native page image scaling and post-processing."),
        sub_item_table = {
            {
                text = _("Enable"),
                checked_func = isEnabled,
                callback = function(touchmenu_instance)
                    local enabled = not isEnabled()
                    setEnabled(enabled)
                    logger.info("ImageProcessing: enabled", enabled)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                    if active_plugin and active_plugin.ui then
                        active_plugin:refreshCurrentPage()
                    end
                end,
                help_text = _("Globally enables or disables Image processing for the current document."),
                keep_menu_open = true,
            },
            {
                text = _("Show in bottom settings menu"),
                checked_func = showBottomConfig,
                callback = function(touchmenu_instance)
                    local show = not showBottomConfig()
                    setShowBottomConfig(show)
                    if show then
                        addToBottomConfigMenu(active_plugin and active_plugin.ui)
                    else
                        Notification:notify(_("Bottom settings menu change will apply when the reader is reopened."))
                    end
                    logger.info("ImageProcessing: show bottom settings menu", show)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
                help_text = _("Shows Image processing controls in the reader bottom settings menu. Hiding takes effect the next time the reader is opened."),
                keep_menu_open = true,
            },
            {
                text_func = function()
                    return T(_("Algorithm: %1"), getAlgorithm().label)
                end,
                help_text = _("Choose the scaler used when comic/archive page images are fitted to the screen. The current page is redrawn when this changes."),
                sub_item_table = getAlgorithmMenuItems(),
            },
            {
                text_func = function()
                    return T(_("Sharpening: %1"), getSharpeningLevel().label)
                end,
                help_text = _("Applies an edge-sharpening pass after scaling. Low is the recommended default for clearer text without strong halos."),
                sub_item_table = getEnhancementMenuItems(SETTING_SHARPENING, DEFAULT_SHARPENING, sharpening_help),
            },
            {
                text_func = function()
                    return T(_("Text darkening: %1"), getTextDarkeningLevel().label)
                end,
                help_text = _("Darkens darker anti-aliased pixels after scaling, making text and panel lines look denser while trying to preserve white areas."),
                sub_item_table = getEnhancementMenuItems(SETTING_TEXT_DARKENING, DEFAULT_TEXT_DARKENING, text_darkening_help),
            },
            {
                text_func = function()
                    return T(_("Auto color correction: %1"), getAutoColorLevel().label)
                end,
                help_text = _("Automatically expands weak tonal range after scaling. Off is safest for black-and-white manga pages."),
                sub_item_table = getEnhancementMenuItems(SETTING_AUTO_COLOR, DEFAULT_AUTO_COLOR, auto_color_help),
            },
            {
                text_func = function()
                    return T(_("Contrast: %1"), getContrastLevel().label)
                end,
                help_text = _("Adjusts contrast after automatic color correction."),
                sub_item_table = getAdjustmentMenuItems(SETTING_CONTRAST, DEFAULT_CONTRAST, contrast_help),
            },
            {
                text_func = function()
                    return T(_("Hue: %1"), getHueLevel().label)
                end,
                help_text = _("Shifts color hue. It has no visible effect on grayscale pages."),
                sub_item_table = getHueMenuItems(),
            },
            {
                text_func = function()
                    return T(_("Saturation: %1"), getSaturationLevel().label)
                end,
                help_text = _("Adjusts color saturation. It has no visible effect on grayscale pages."),
                sub_item_table = getAdjustmentMenuItems(SETTING_SATURATION, DEFAULT_SATURATION, saturation_help),
            },
            {
                text_func = function()
                    return T(_("Brightness: %1"), getBrightnessLevel().label)
                end,
                help_text = _("Adjusts image brightness after scaling."),
                sub_item_table = getAdjustmentMenuItems(SETTING_BRIGHTNESS, DEFAULT_BRIGHTNESS, brightness_help),
            },
            {
                text = _("Reset settings to defaults"),
                callback = function(touchmenu_instance)
                    resetSettingsToDefaults()
                    logger.info("ImageProcessing: reset settings to defaults")
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                    if active_plugin and active_plugin.ui then
                        active_plugin:refreshCurrentPage()
                    end
                end,
                help_text = _("Restores Image processing settings to their default values."),
                keep_menu_open = true,
            },
            {
                text = _("Native library status"),
                callback = function()
                    local lib = loadNative()
                    local text = _("Not loaded")
                    if lib then
                        local version_func = getNativeFunction(lib, "koreader_imageprocessing_version")
                        if version_func then
                            text = T(_("Loaded: %1"), ffi.string(version_func()))
                        else
                            text = _("Loaded, but version function is missing")
                        end
                    end
                    UIManager:show(InfoMessage:new{ text = text })
                end,
                help_text = _("Shows whether the native image processing library was loaded. If it is not loaded, KOReader's default scaler is used."),
                keep_menu_open = true,
            },
        },
    }
end

function ImageProcessing:addToMainMenu(menu_items)
    menu_items.imageprocessing = getImageProcessingMenuItem()
    menu_items.imageprocessing.sorting_hint = "typeset"
end

return ImageProcessing
