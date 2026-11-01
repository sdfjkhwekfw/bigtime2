// BigTime2 —— 锁屏玻璃时钟（时间2 独立插件，从 com.axs.bigtime 提取核心视觉：玻璃层 + 文本渐变 + 可变字体）
// 挂载点：CSProminentTimeView（原生锁屏时间视图）
// 偏好域：com.xiaoyu.bigtime2
//   启用开关              Enabled            (BOOL, 默认 0)
//   隐藏原生时间文字       HideStockTime      (BOOL, 默认 0；开启只隐藏时间 label，玻璃层保留)
//   玻璃 模糊强度          GlassBlur          (CGFloat, 默认 20)
//   玻璃 圆角/厚度         GlassThickness     (CGFloat, 默认 18)
//   玻璃 白色调透明度      TintAlpha          (CGFloat, 默认 0.22)
//   渐变 开关              GradientEnabled    (BOOL, 默认 0)
//   渐变 内色              GradientInnerColor (FFFFFF,100 或 6 位 hex)
//   渐变 外色              GradientOuterColor
//   字体 文件              FontFile           (bundle 内文件名，如 y.otf；留空=系统数字字体)
//   字体 字号              FontSize           (默认 82；0=跟随原生)
//   字体 粗细              FontWeight         (系统字体 0~1；自定义字体忽略)

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <substrate.h>

#define PREFS_DOMAIN @"com.xiaoyu.bigtime2"

static NSDictionary *loadPrefs(void) {
    NSDictionary *reg = [[NSUserDefaults standardUserDefaults] persistentDomainForName:PREFS_DOMAIN];
    return reg ?: @{};
}

static BOOL prefBool(NSDictionary *p, NSString *k, BOOL d) {
    id v = p[k];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [v boolValue];
    return d;
}

static CGFloat prefFloat(NSDictionary *p, NSString *k, CGFloat d) {
    id v = p[k];
    if ([v respondsToSelector:@selector(doubleValue)]) return [v doubleValue];
    return d;
}

static UIColor *colorFromHex(NSString *raw, NSString *fallback) {
    if (![raw isKindOfClass:[NSString class]] || !raw.length) raw = fallback;
    raw = [[raw stringByReplacingOccurrencesOfString:@"#" withString:@""]
           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].uppercaseString;
    NSString *hex = raw;
    NSRange comma = [raw rangeOfString:@","];
    if (comma.location != NSNotFound) hex = [raw substringToIndex:comma.location];
    hex = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    unsigned v = 0;
    if (hex.length == 6 && [[NSScanner scannerWithString:hex] scanHexInt:&v]) {
        CGFloat r = ((v >> 16) & 0xFF) / 255.0;
        CGFloat g = ((v >> 8) & 0xFF) / 255.0;
        CGFloat b = (v & 0xFF) / 255.0;
        return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
    }
    return [UIColor whiteColor];
}

static UIView *gGlass = nil;            // 玻璃层（blur + tint）
static CAGradientLayer *gGrad = nil;    // 渐变层
static BOOL gFontRegistered = NO;

static NSString *fontBundlePath(NSString *name) {
    NSBundle *b = [NSBundle bundleWithPath:@"/var/jb/Library/PreferenceBundles/BigTime2Prefs.bundle"];
    if (b) {
        NSString *p = [b pathForResource:name ofType:nil];
        if (p) return p;
    }
    NSString *p2 = [@"/var/jb/Library/Fonts/" stringByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:p2]) return p2;
    return nil;
}

static void registerFont(NSString *path) {
    if (gFontRegistered || !path.length) return;
    NSURL *url = [NSURL fileURLWithPath:path];
    CFErrorRef err = NULL;
    if (CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &err)) {
        gFontRegistered = YES;
    }
}

static UIFont *makeFont(NSDictionary *prefs, UIFont *stockFont) {
    NSString *file = prefs[@"FontFile"];
    NSString *path = nil;
    if ([file isKindOfClass:[NSString class]] && file.length) {
        path = fontBundlePath(file);
        if (path) registerFont(path);
    }
    CGFloat size = prefFloat(prefs, @"FontSize", 0);
    if (size <= 1) size = stockFont ? stockFont.pointSize : 82;

    if (path) {
        NSString *postName = [[path lastPathComponent] stringByDeletingPathExtension];
        UIFont *f = [UIFont fontWithName:postName size:size];
        if (f) return f;
        // 注册后仍取不到名字时，尝试全局扫一遍注册过的字体
        for (NSString *family in [UIFont familyNames]) {
            for (NSString *name in [UIFont fontNamesForFamilyName:family]) {
                if ([name rangeOfString:postName options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [family rangeOfString:postName options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    UIFont *f2 = [UIFont fontWithName:name size:size];
                    if (f2) return f2;
                }
            }
        }
    }
    // 系统数字字体 + 字重变体
    CGFloat weight = prefFloat(prefs, @"FontWeight", 0.55);
    UIFontDescriptor *d = [UIFontDescriptor fontDescriptorWithFontAttributes:@{
        UIFontDescriptorFamilyAttribute: @".SF UI",
        UIFontDescriptorTraitsAttribute: @{UIFontWeightTrait: @(weight)}
    }];
    UIFont *f = [UIFont fontWithDescriptor:d size:size];
    return f ?: [UIFont systemFontOfSize:size weight:weight];
}

// 把文字渲染成黑色形状图（用于渐变 mask）
static UIImage *textMaskImage(UILabel *label) {
    if (!label.text.length) return nil;
    UIGraphicsBeginImageContextWithOptions(label.bounds.size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIFont *f = label.font ?: [UIFont systemFontOfSize:82];
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = label.textAlignment;
    [label.text drawInRect:label.bounds withAttributes:@{
        NSFontAttributeName: f,
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSKernAttributeName: @(0),
        NSParagraphStyleAttributeName: ps
    }];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

static void applyGlass(UIView *timeView) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ applyGlass(timeView); });
        return;
    }
    NSDictionary *prefs = loadPrefs();
    if (!prefBool(prefs, @"Enabled", 0)) {
        if (gGlass) { [gGlass removeFromSuperview]; gGlass = nil; }
        if (gGrad) { [gGrad removeFromSuperlayer]; gGrad = nil; }
        return;
    }

    UILabel *tl = nil;
    for (UIView *sub in timeView.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) { tl = (UILabel *)sub; break; }
    }
    if (!tl) return;

    // 隐藏原生时间文字（HideStockTime=YES）：只隐藏 label，玻璃层保留
    tl.hidden = prefBool(prefs, @"HideStockTime", 0);

    // ---- 字体 ----
    UIFont *stock = tl.font;
    tl.font = makeFont(prefs, stock);
    CGRect frame = tl.frame;

    // ---- 玻璃层（blur backdrop + 白色调）----
    CGFloat blur = prefFloat(prefs, @"GlassBlur", 20);
    if (!gGlass || gGlass.superview != timeView) {
        UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
        UIVisualEffectView *ve = [[UIVisualEffectView alloc] initWithEffect:eff];
        ve.frame = frame;
        ve.layer.cornerRadius = prefFloat(prefs, @"GlassThickness", 18);
        ve.clipsToBounds = YES;
        [timeView insertSubview:ve atIndex:0];
        gGlass = ve;
        UIView *tint = [[UIView alloc] initWithFrame:ve.bounds];
        tint.backgroundColor = [UIColor whiteColor];
        tint.alpha = prefFloat(prefs, @"TintAlpha", 0.22);
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [ve.contentView addSubview:tint];
    } else {
        gGlass.frame = frame;
        gGlass.layer.cornerRadius = prefFloat(prefs, @"GlassThickness", 18);
        ((UIView *)gGlass.subviews.firstObject).alpha = prefFloat(prefs, @"TintAlpha", 0.22);
    }

    // ---- 文本渐变（CAGradientLayer + 文字形状 mask）----
    if (prefBool(prefs, @"GradientEnabled", 0)) {
        if (!gGrad || gGrad.superlayer != tl.layer) {
            CAGradientLayer *grad = [CAGradientLayer layer];
            grad.frame = tl.bounds;
            UIColor *inner = colorFromHex(prefs[@"GradientInnerColor"], @"FFFFFF");
            UIColor *outer = colorFromHex(prefs[@"GradientOuterColor"], @"9FB4FF");
            grad.colors = @[(id)outer.CGColor, (id)inner.CGColor, (id)outer.CGColor];
            grad.startPoint = CGPointMake(0, 0);
            grad.endPoint = CGPointMake(1, 0);
            CALayer *mask = [CALayer layer];
            mask.frame = tl.bounds;
            mask.contents = (__bridge id)textMaskImage(tl).CGImage;
            grad.mask = mask;
            [tl.layer addSublayer:grad];
            gGrad = grad;
        } else {
            gGrad.frame = tl.bounds;
            gGrad.mask.frame = tl.bounds;
        }
        tl.textColor = [UIColor clearColor];
    } else {
        if (gGrad) { [gGrad removeFromSuperlayer]; gGrad = nil; }
        tl.textColor = [UIColor whiteColor];
    }
}

// ===================== hook：原生时间视图 =====================
%hook CSProminentTimeView
- (void)setHidden:(BOOL)hidden {
    NSDictionary *p = loadPrefs();
    if (prefBool(p, @"Enabled", 0) && prefBool(p, @"HideStockTime", 0)) {
        // 隐藏时间文字由 applyGlass 内对 label 处理，这里放行系统控制
        %orig(hidden);
    } else {
        %orig(hidden);
    }
}
- (void)layoutSubviews {
    %orig;
    applyGlass((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    applyGlass((UIView *)self);
}
%end

%ctor {
    // 偏好变更实时刷新
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        (CFNotificationCallback)^(CFNotificationCenterRef c, void *o, CFStringRef n, const void *d, CFDictionaryRef u){
            dispatch_async(dispatch_get_main_queue(), ^{
                UIView *tv = nil;
                for (UIWindow *win in [UIApplication sharedApplication].windows) {
                    for (UIView *v in win.subviews) {
                        if ([NSStringFromClass([v class]) isEqualToString:@"CSProminentTimeView"]) { tv = v; break; }
                    }
                    if (tv) break;
                }
                if (tv) applyGlass(tv);
            });
        }, CFSTR("com.xiaoyu.bigtime2.prefs"), CFNotificationSuspensionBehaviorCoalesce);
}
