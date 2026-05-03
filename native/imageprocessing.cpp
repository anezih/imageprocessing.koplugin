#include <cstdint>
#include <cstring>
#include <exception>
#include <cmath>
#include <algorithm>
#include <vector>

#include "avir/avir.h"
#include "avir/lancir.h"

extern "C" {

struct ImageProcessingBlitBuffer {
    unsigned int w;
    unsigned int pixel_stride;
    unsigned int h;
    size_t stride;
    uint8_t *data;
    uint8_t config;
};

enum ImageProcessingAlgorithm {
    IMAGEPROCESSING_LANCZOS2 = 0,
    IMAGEPROCESSING_LANCZOS3 = 1,
    IMAGEPROCESSING_AVIR = 2,
    IMAGEPROCESSING_AVIR_LOW_RINGING = 3,
    IMAGEPROCESSING_AVIR_ULTRA_LOW_RINGING = 4,
    IMAGEPROCESSING_AVIR_LOW_ALIASING = 5,
    IMAGEPROCESSING_AVIR_ULTRA_LOW_ALIASING = 6,
};

const char *koreader_imageprocessing_version(void)
{
    return "AVIR/LANCIR 3.1 + color postprocess";
}

static uint8_t clamp_u8(double value)
{
    if (value <= 0.0) {
        return 0;
    }
    if (value >= 255.0) {
        return 255;
    }
    return static_cast<uint8_t>(value + 0.5);
}

static int clamp_i(int value, int min_value, int max_value)
{
    if (value < min_value) {
        return min_value;
    }
    if (value > max_value) {
        return max_value;
    }
    return value;
}

static int color_channel_count(int channels)
{
    return channels == 4 ? 3 : channels == 2 ? 1 : channels;
}

static double sharpen_amount(int level)
{
    switch (level) {
    case 1:
        return 0.25;
    case 2:
        return 0.50;
    case 3:
        return 0.65;
    default:
        if (level <= 0) {
            return 0.0;
        }
        if (level <= 3) {
            return 0.65;
        }
        return 0.65 + 1.35 * static_cast<double>(clamp_i(level, 4, 100) - 3) / 97.0;
    }
}

static double darken_amount(int level)
{
    switch (level) {
    case 1:
        return 0.18;
    case 2:
        return 0.32;
    case 3:
        return 0.38;
    default:
        if (level <= 0) {
            return 0.0;
        }
        return 0.45 * static_cast<double>(clamp_i(level, 0, 100)) / 100.0;
    }
}

static double auto_color_amount(int level)
{
    switch (level) {
    case 1:
        return 0.35;
    case 2:
        return 0.65;
    case 3:
        return 0.85;
    default:
        if (level <= 0) {
            return 0.0;
        }
        return static_cast<double>(clamp_i(level, 0, 100)) / 100.0;
    }
}

static double contrast_factor(int level)
{
    switch (level) {
    case -2:
        return 0.75;
    case -1:
        return 0.90;
    case 1:
        return 1.12;
    case 2:
        return 1.25;
    case 3:
        return 1.40;
    default:
        return 1.0;
    }
}

static double saturation_factor(int level)
{
    switch (level) {
    case -2:
        return 0.50;
    case -1:
        return 0.75;
    case 1:
        return 1.15;
    case 2:
        return 1.30;
    case 3:
        return 1.50;
    default:
        return 1.0;
    }
}

static double brightness_offset(int level)
{
    switch (level) {
    case -2:
        return -24.0;
    case -1:
        return -12.0;
    case 1:
        return 12.0;
    case 2:
        return 24.0;
    case 3:
        return 36.0;
    default:
        return 0.0;
    }
}

static int channel_count(const ImageProcessingBlitBuffer *bb)
{
    const int type = (bb->config & 0xF0) >> 4;
    switch (type) {
    case 1: // BB8
        return 1;
    case 2: // BB8A
        return 2;
    case 4: // BBRGB24
        return 3;
    case 5: // BBRGB32
        return 4;
    default:
        return 0;
    }
}

static bool copy_to_compact(const ImageProcessingBlitBuffer *bb, int channels, std::vector<uint8_t> &out)
{
    const size_t row_bytes = static_cast<size_t>(bb->w) * static_cast<size_t>(channels);
    const size_t total_bytes = row_bytes * static_cast<size_t>(bb->h);
    if (row_bytes == 0 || bb->data == nullptr || bb->stride < row_bytes) {
        return false;
    }

    out.resize(total_bytes);
    for (unsigned int y = 0; y < bb->h; ++y) {
        std::memcpy(out.data() + row_bytes * y, bb->data + bb->stride * y, row_bytes);
    }
    return true;
}

static bool copy_from_compact(const std::vector<uint8_t> &in, ImageProcessingBlitBuffer *bb, int channels)
{
    const size_t row_bytes = static_cast<size_t>(bb->w) * static_cast<size_t>(channels);
    if (row_bytes == 0 || bb->data == nullptr || bb->stride < row_bytes) {
        return false;
    }

    for (unsigned int y = 0; y < bb->h; ++y) {
        std::memcpy(bb->data + bb->stride * y, in.data() + row_bytes * y, row_bytes);
    }
    return true;
}

static void scale_with_avir(
    const uint8_t *src,
    int src_width,
    int src_height,
    uint8_t *dst,
    int dst_width,
    int dst_height,
    int channels,
    int algorithm)
{
    switch (algorithm) {
    case IMAGEPROCESSING_AVIR_LOW_RINGING: {
        avir::CImageResizer<> resizer(8, 0, avir::CImageResizerParamsLR());
        resizer.resizeImage(src, src_width, src_height, 0, dst, dst_width, dst_height, channels, 0);
        break;
    }
    case IMAGEPROCESSING_AVIR_ULTRA_LOW_RINGING: {
        avir::CImageResizer<> resizer(8, 0, avir::CImageResizerParamsULR());
        resizer.resizeImage(src, src_width, src_height, 0, dst, dst_width, dst_height, channels, 0);
        break;
    }
    case IMAGEPROCESSING_AVIR_LOW_ALIASING: {
        avir::CImageResizer<> resizer(8, 0, avir::CImageResizerParamsHigh());
        resizer.resizeImage(src, src_width, src_height, 0, dst, dst_width, dst_height, channels, 0);
        break;
    }
    case IMAGEPROCESSING_AVIR_ULTRA_LOW_ALIASING: {
        avir::CImageResizer<> resizer(8, 0, avir::CImageResizerParamsUltra());
        resizer.resizeImage(src, src_width, src_height, 0, dst, dst_width, dst_height, channels, 0);
        break;
    }
    default: {
        avir::CImageResizer<> resizer(8);
        resizer.resizeImage(src, src_width, src_height, 0, dst, dst_width, dst_height, channels, 0);
        break;
    }
    }
}

static void apply_sharpen(
    std::vector<uint8_t> &image,
    int width,
    int height,
    int channels,
    int level)
{
    const double amount = sharpen_amount(level);
    if (amount <= 0.0 || width < 3 || height < 3) {
        return;
    }

    const int color_channels = color_channel_count(channels);
    std::vector<uint8_t> src(image);
    for (int y = 1; y < height - 1; ++y) {
        for (int x = 1; x < width - 1; ++x) {
            const size_t idx = (static_cast<size_t>(y) * width + x) * channels;
            for (int c = 0; c < color_channels; ++c) {
                const size_t center = idx + c;
                const int blurred =
                    src[((static_cast<size_t>(y - 1) * width + (x - 1)) * channels) + c] +
                    2 * src[((static_cast<size_t>(y - 1) * width + x) * channels) + c] +
                    src[((static_cast<size_t>(y - 1) * width + (x + 1)) * channels) + c] +
                    2 * src[((static_cast<size_t>(y) * width + (x - 1)) * channels) + c] +
                    4 * src[center] +
                    2 * src[((static_cast<size_t>(y) * width + (x + 1)) * channels) + c] +
                    src[((static_cast<size_t>(y + 1) * width + (x - 1)) * channels) + c] +
                    2 * src[((static_cast<size_t>(y + 1) * width + x) * channels) + c] +
                    src[((static_cast<size_t>(y + 1) * width + (x + 1)) * channels) + c];
                const double blur = blurred / 16.0;
                const double detail = static_cast<double>(src[center]) - blur;
                image[center] = clamp_u8(static_cast<double>(src[center]) + amount * detail);
            }
        }
    }
}

static void apply_text_darken(
    std::vector<uint8_t> &image,
    int width,
    int height,
    int channels,
    int level)
{
    const double amount = darken_amount(level);
    if (amount <= 0.0) {
        return;
    }

    const int color_channels = color_channel_count(channels);
    const size_t pixel_count = static_cast<size_t>(width) * static_cast<size_t>(height);
    std::vector<uint8_t> luma(pixel_count);
    for (size_t i = 0; i < pixel_count; ++i) {
        const size_t idx = i * static_cast<size_t>(channels);
        if (color_channels >= 3) {
            luma[i] = static_cast<uint8_t>((77 * image[idx] + 150 * image[idx + 1] + 29 * image[idx + 2]) >> 8);
        } else {
            luma[i] = image[idx];
        }
    }

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const size_t i = static_cast<size_t>(y) * static_cast<size_t>(width) + static_cast<size_t>(x);
            const int pixel_luma = luma[i];

            if (pixel_luma >= 245 || pixel_luma <= 12) {
                continue;
            }

            int luma_sum = 0;
            int dark_neighbors = 0;
            int sample_count = 0;
            for (int oy = -1; oy <= 1; ++oy) {
                const int sy = y + oy;
                if (sy < 0 || sy >= height) {
                    continue;
                }
                for (int ox = -1; ox <= 1; ++ox) {
                    const int sx = x + ox;
                    if (sx < 0 || sx >= width) {
                        continue;
                    }
                    const int sample_luma = luma[static_cast<size_t>(sy) * static_cast<size_t>(width) + static_cast<size_t>(sx)];
                    luma_sum += sample_luma;
                    if (sample_luma < 170) {
                        ++dark_neighbors;
                    }
                    ++sample_count;
                }
            }

            const double local_luma = static_cast<double>(luma_sum) / static_cast<double>(sample_count);
            const double background_weight = std::max(0.0, std::min(1.0, (local_luma - 175.0) / 55.0));
            const double isolated_stroke_weight = std::max(0.0, 1.0 - static_cast<double>(dark_neighbors - 1) / 5.0);
            const double antialias_weight = pixel_luma < 45
                ? 0.35
                : std::max(0.0, std::min(1.0, (235.0 - static_cast<double>(pixel_luma)) / 170.0));
            const double effective_amount = amount * background_weight * isolated_stroke_weight * antialias_weight;
            if (effective_amount <= 0.0) {
                continue;
            }

            const size_t idx = i * static_cast<size_t>(channels);
            const double factor = 1.0 - effective_amount;
            for (int c = 0; c < color_channels; ++c) {
                image[idx + c] = clamp_u8(static_cast<double>(image[idx + c]) * factor);
            }
        }
    }
}

static void apply_auto_color(
    std::vector<uint8_t> &image,
    int width,
    int height,
    int channels,
    int level)
{
    const double amount = auto_color_amount(level);
    if (amount <= 0.0) {
        return;
    }

    const int color_channels = color_channel_count(channels);
    uint8_t min_value[3] = { 255, 255, 255 };
    uint8_t max_value[3] = { 0, 0, 0 };
    const size_t pixel_count = static_cast<size_t>(width) * static_cast<size_t>(height);
    for (size_t i = 0; i < pixel_count; ++i) {
        const size_t idx = i * static_cast<size_t>(channels);
        for (int c = 0; c < color_channels; ++c) {
            min_value[c] = std::min(min_value[c], image[idx + c]);
            max_value[c] = std::max(max_value[c], image[idx + c]);
        }
    }

    for (size_t i = 0; i < pixel_count; ++i) {
        const size_t idx = i * static_cast<size_t>(channels);
        for (int c = 0; c < color_channels; ++c) {
            const int range = static_cast<int>(max_value[c]) - static_cast<int>(min_value[c]);
            if (range < 32) {
                continue;
            }
            const double corrected = (static_cast<double>(image[idx + c]) - min_value[c]) * 255.0 / range;
            const double blended = image[idx + c] + amount * (corrected - image[idx + c]);
            image[idx + c] = clamp_u8(blended);
        }
    }
}

static void apply_brightness_contrast(
    std::vector<uint8_t> &image,
    int width,
    int height,
    int channels,
    int contrast_level,
    int brightness_level)
{
    const double contrast = contrast_factor(contrast_level);
    const double brightness = brightness_offset(brightness_level);
    if (contrast == 1.0 && brightness == 0.0) {
        return;
    }

    const int color_channels = color_channel_count(channels);
    const size_t pixel_count = static_cast<size_t>(width) * static_cast<size_t>(height);
    for (size_t i = 0; i < pixel_count; ++i) {
        const size_t idx = i * static_cast<size_t>(channels);
        for (int c = 0; c < color_channels; ++c) {
            const double pixel = static_cast<double>(image[idx + c]);
            const double contrasted = contrast < 1.0
                ? 255.0 - (255.0 - pixel) * contrast
                : (pixel - 128.0) * contrast + 128.0;
            const double value = contrasted + brightness;
            image[idx + c] = clamp_u8(value);
        }
    }
}

static void rgb_to_hsv(double r, double g, double b, double &h, double &s, double &v)
{
    const double max_value = std::max(r, std::max(g, b));
    const double min_value = std::min(r, std::min(g, b));
    const double delta = max_value - min_value;
    v = max_value;
    s = max_value <= 0.0 ? 0.0 : delta / max_value;

    if (delta <= 0.0) {
        h = 0.0;
    } else if (max_value == r) {
        h = 60.0 * std::fmod(((g - b) / delta), 6.0);
    } else if (max_value == g) {
        h = 60.0 * (((b - r) / delta) + 2.0);
    } else {
        h = 60.0 * (((r - g) / delta) + 4.0);
    }
    if (h < 0.0) {
        h += 360.0;
    }
}

static void hsv_to_rgb(double h, double s, double v, double &r, double &g, double &b)
{
    const double c = v * s;
    const double x = c * (1.0 - std::fabs(std::fmod(h / 60.0, 2.0) - 1.0));
    const double m = v - c;

    double rp = 0.0;
    double gp = 0.0;
    double bp = 0.0;
    if (h < 60.0) {
        rp = c;
        gp = x;
    } else if (h < 120.0) {
        rp = x;
        gp = c;
    } else if (h < 180.0) {
        gp = c;
        bp = x;
    } else if (h < 240.0) {
        gp = x;
        bp = c;
    } else if (h < 300.0) {
        rp = x;
        bp = c;
    } else {
        rp = c;
        bp = x;
    }

    r = rp + m;
    g = gp + m;
    b = bp + m;
}

static void apply_hue_saturation(
    std::vector<uint8_t> &image,
    int width,
    int height,
    int channels,
    int hue_shift,
    int saturation_level)
{
    if (color_channel_count(channels) < 3) {
        return;
    }

    const double saturation = saturation_factor(saturation_level);
    if (hue_shift == 0 && saturation == 1.0) {
        return;
    }

    const size_t pixel_count = static_cast<size_t>(width) * static_cast<size_t>(height);
    for (size_t i = 0; i < pixel_count; ++i) {
        const size_t idx = i * static_cast<size_t>(channels);
        double h;
        double s;
        double v;
        rgb_to_hsv(image[idx] / 255.0, image[idx + 1] / 255.0, image[idx + 2] / 255.0, h, s, v);
        h = std::fmod(h + static_cast<double>(hue_shift) + 360.0, 360.0);
        s = std::max(0.0, std::min(1.0, s * saturation));

        double r;
        double g;
        double b;
        hsv_to_rgb(h, s, v, r, g, b);
        image[idx] = clamp_u8(r * 255.0);
        image[idx + 1] = clamp_u8(g * 255.0);
        image[idx + 2] = clamp_u8(b * 255.0);
    }
}

static void apply_postprocess(
    std::vector<uint8_t> &image,
    int width,
    int height,
    int channels,
    int sharpen_level,
    int darken_level,
    int auto_color_level,
    int contrast_level,
    int hue_shift,
    int saturation_level,
    int brightness_level)
{
    apply_auto_color(image, width, height, channels, auto_color_level);
    apply_brightness_contrast(image, width, height, channels, contrast_level, brightness_level);
    apply_hue_saturation(image, width, height, channels, hue_shift, saturation_level);
    apply_sharpen(image, width, height, channels, sharpen_level);
    apply_text_darken(image, width, height, channels, darken_level);
}

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
    int brightness_level)
{
    if (src == nullptr || dst == nullptr || src->w == 0 || src->h == 0 || dst->w == 0 || dst->h == 0) {
        return -1;
    }

    const int channels = channel_count(src);
    if (channels == 0 || channels != channel_count(dst)) {
        return -2;
    }

    try {
        std::vector<uint8_t> src_compact;
        if (!copy_to_compact(src, channels, src_compact)) {
            return -3;
        }

        std::vector<uint8_t> dst_compact(
            static_cast<size_t>(dst->w) * static_cast<size_t>(dst->h) * static_cast<size_t>(channels));

        if (algorithm == IMAGEPROCESSING_LANCZOS2 || algorithm == IMAGEPROCESSING_LANCZOS3) {
            avir::CLancIR lancir;
            avir::CLancIRParams params;
            params.la = algorithm == IMAGEPROCESSING_LANCZOS2 ? 2.0 : 3.0;
            if (lancir.resizeImage(src_compact.data(), static_cast<int>(src->w), static_cast<int>(src->h),
                    dst_compact.data(), static_cast<int>(dst->w), static_cast<int>(dst->h),
                    channels, &params) != static_cast<int>(dst->h)) {
                return -4;
            }
        } else {
            scale_with_avir(src_compact.data(), static_cast<int>(src->w), static_cast<int>(src->h),
                dst_compact.data(), static_cast<int>(dst->w), static_cast<int>(dst->h),
                channels, algorithm);
        }

        apply_postprocess(dst_compact, static_cast<int>(dst->w), static_cast<int>(dst->h),
            channels, sharpen_level, darken_level, auto_color_level, contrast_level,
            hue_shift, saturation_level, brightness_level);

        if (!copy_from_compact(dst_compact, dst, channels)) {
            return -5;
        }
    } catch (const std::exception &) {
        return -6;
    } catch (...) {
        return -7;
    }

    return 0;
}

}
