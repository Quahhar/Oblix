import 'dart:ui';

import 'package:flutter/material.dart';
import '../theme/oblix_theme.dart';
import '../theme/theme_controller.dart';

/// Small shared pieces of the "Paper" design language. Every screen composes
/// these instead of re-styling raw Material widgets.

/// The Liquid Glass treatment, factored out so every control gets the same
/// one: a blurred backdrop, a translucent tint of the button's own colour, a
/// diagonal sheen, and a brightened edge.
///
/// With the preference off this collapses to the plain opaque [Material] the
/// design used before, so callers never branch on the setting themselves.
/// [shape] is an [OutlinedBorder] because the glass edge is painted by
/// overriding the shape's own side.
///
/// Mobile performance: a backdrop blur costs a read-back of everything painted
/// beneath it, and a screen can hold a dozen of these at once. Two things keep
/// that affordable. The blur uses [BackdropFilter.grouped], so every control
/// under the app's [BackdropGroup] shares one read instead of one each. And
/// [blur] can be turned off for controls where the read would be wasted — a
/// small chip, or anything already sitting inside a blurred surface — which
/// keeps the tint, sheen, and bright edge but skips the expensive part.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.shape,
    required this.color,
    required this.child,
    this.glassAlpha = 0.30,
    this.blurSigma = 16,
    this.blur = true,
  });

  /// Painted opaque when the preference is off, and used as the tint when on.
  final Color color;

  final OutlinedBorder shape;
  final Widget child;

  /// How much of [color] survives the blur. Filled call-to-action buttons pass
  /// a higher value so their `onAccent` label keeps its contrast.
  final double glassAlpha;

  final double blurSigma;

  /// Whether to read and blur the backdrop. See the class comment.
  final bool blur;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeController.instance.liquidGlass,
      builder: (context, enabled, _) {
        if (!enabled) {
          return Material(
            color: color,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: child,
          );
        }

        final c = OblixColors.of(context);
        final dark = Theme.of(context).brightness == Brightness.dark;
        final glassShape = shape.copyWith(
          side: BorderSide(
            color: Colors.white.withValues(alpha: dark ? 0.20 : 0.62),
          ),
        );
        // Without a backdrop read the tint has to carry the whole surface, so
        // it leans more opaque; with one it can stay light and let the blur
        // show through.
        final surface = DecoratedBox(
          decoration: ShapeDecoration(
            shape: glassShape,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: dark ? 0.14 : 0.38),
                color.withValues(
                  alpha: blur ? glassAlpha : (glassAlpha + 0.4).clamp(0.0, 1.0),
                ),
                c.accentSoft.withValues(alpha: 0.24),
              ],
              stops: const [0, 0.52, 1],
            ),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        );

        return ClipPath(
          clipper: ShapeBorderClipper(
            shape: shape,
            textDirection: Directionality.maybeOf(context),
          ),
          child: blur
              ? BackdropFilter.grouped(
                  filter: ImageFilter.blur(
                    sigmaX: blurSigma,
                    sigmaY: blurSigma,
                  ),
                  child: surface,
                )
              : surface,
        );
      },
    );
  }
}

/// UPPERCASE section header ("PINNED", "REMIND ME"), optionally with a rule
/// line running to the right edge (Tasks screen groups).
class SectionEyebrow extends StatelessWidget {
  final String text;
  final Color? color;
  final bool rule;
  final EdgeInsetsGeometry padding;

  const SectionEyebrow(
    this.text, {
    super.key,
    this.color,
    this.rule = false,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 8),
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final label = Text(
      text.toUpperCase(),
      style: OblixType.eyebrow(c, color: color),
    );
    return Padding(
      padding: padding,
      child: rule
          ? Row(
              children: [
                label,
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 1,
                    color: (color ?? c.ink).withValues(alpha: 0.15),
                  ),
                ),
              ],
            )
          : label,
    );
  }
}

/// The standard card: surface background, hairline border, 16px radius.
class PaperCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const PaperCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final body = padding != null
        ? Padding(padding: padding!, child: child)
        : child;
    final card = Material(
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: onTap == null && onLongPress == null
          ? body
          : InkWell(onTap: onTap, onLongPress: onLongPress, child: body),
    );
    return margin != null ? Padding(padding: margin!, child: card) : card;
  }
}

/// Round pill button. [filled] = terracotta CTA; otherwise a 1.5px terracotta
/// outline ("New" on Notebooks).
class AccentPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool filled;
  final VoidCallback? onTap;

  const AccentPill({
    super.key,
    required this.label,
    this.icon,
    this.filled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final fg = filled ? c.onAccent : c.accent;
    return LiquidGlass(
      color: filled ? c.accent : Colors.transparent,
      // A filled CTA keeps most of its terracotta through the blur so the
      // onAccent label stays readable over whatever it happens to sit on.
      glassAlpha: filled ? 0.66 : 0.16,
      shape: StadiumBorder(
        side: filled
            ? BorderSide.none
            : BorderSide(color: c.accent, width: 1.5),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: fg),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: OblixType.ui(
                  c,
                  size: 12.5,
                  weight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pill-shaped button with caller-supplied contents — the search/ask bar, the
/// empty-state "Write" chip, the sign-in call to action. Glass-aware like the
/// rest of the controls.
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
    this.color,
    this.borderColor,
    this.glassAlpha = 0.30,
    this.blur = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  /// Defaults to the card surface; pass the accent for a call to action.
  final Color? color;
  final Color? borderColor;
  final double glassAlpha;

  /// Small repeated chips pass false — see [LiquidGlass.blur].
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final side = borderColor == null
        ? BorderSide(color: c.hairline)
        : BorderSide(color: borderColor!);
    return LiquidGlass(
      color: color ?? c.surface,
      glassAlpha: glassAlpha,
      blur: blur,
      shape: StadiumBorder(side: side),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 36px circular icon button on a surfaceAlt disc (editor top bar, back
/// buttons on detail screens).
///
/// [size] is the painted disc. The area that actually responds to a finger is
/// grown to [kMinInteractiveDimension] (48) around it, because the design's
/// 32px discs are well under the touch-target minimum on both Android and iOS
/// and these are the app's back buttons. Nothing moves visually — the disc is
/// centred in the larger box — so laying out two of them side by side still
/// looks the same, their targets simply meet in the middle.
class CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;

  const CircleIconButton(
    this.icon, {
    super.key,
    this.onTap,
    this.tooltip,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final target = size < kMinInteractiveDimension
        ? kMinInteractiveDimension
        : size;
    final disc = LiquidGlass(
      color: c.surfaceAlt,
      shape: CircleBorder(side: BorderSide(color: c.hairline)),
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(icon, size: size * 0.47, color: c.ink),
      ),
    );
    final button = SizedBox(
      width: target,
      height: target,
      // The gesture lives on the outer box so the target is the full 48;
      // the splash stays disc-sized so it still reads as a round button.
      child: InkResponse(
        onTap: onTap,
        radius: size / 2,
        customBorder: const CircleBorder(),
        child: Center(child: disc),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: button) : button;
  }
}

/// The user's initial in a round avatar (home header, settings).
class OblixAvatar extends StatelessWidget {
  final String? name;
  final double size;
  final VoidCallback? onTap;

  const OblixAvatar({super.key, this.name, this.size = 30, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final trimmed = name?.trim() ?? '';
    final initial = trimmed.isEmpty ? 'O' : trimmed[0].toUpperCase();
    return LiquidGlass(
      color: c.avatarBg,
      glassAlpha: 0.55,
      // Avatars are small and often sit inside the already-blurred dock, where
      // a second backdrop read buys nothing visible.
      blur: false,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: Text(
              initial,
              style: OblixType.ui(
                c,
                size: size * 0.4,
                weight: FontWeight.w600,
                color: c.avatarInk,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled row inside a Settings or Profile card: icon tile, label,
/// optional value, and either a chevron or caller-supplied trailing widget.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
    this.trailing,
    this.showChevron = true,
  });

  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 15, color: c.avatarInk),
            ),
            const SizedBox(width: 13),
            Expanded(child: Text(label, style: OblixType.ui(c, size: 14.5))),
            if (value != null)
              Text(value!, style: OblixType.ui(c, size: 13, color: c.inkMuted)),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ] else if (showChevron) ...[
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 16, color: c.outline),
            ],
          ],
        ),
      ),
    );
  }
}

/// Drag handle at the top of every bottom sheet.
class SheetGrabHandle extends StatelessWidget {
  const SheetGrabHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Center(
      child: Container(
        width: 40,
        height: 5,
        margin: const EdgeInsets.only(top: 10, bottom: 16),
        decoration: BoxDecoration(
          color: c.outline.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(99),
        ),
      ),
    );
  }
}

/// Styled placeholder sheet for designed-but-not-yet-built features
/// (Audio, Scan, Sketch, Web clip, …).
Future<void> showComingSoon(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String subtitle,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) {
      final c = OblixColors.of(context);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetGrabHandle(),
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: c.accent, size: 26),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                style: TextStyle(
                  fontFamily: OblixType.serif,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: c.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: OblixType.ui(c, size: 13.5, color: c.inkSecondary),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: c.chip,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('COMING SOON', style: OblixType.eyebrow(c)),
              ),
            ],
          ),
        ),
      );
    },
  );
}
