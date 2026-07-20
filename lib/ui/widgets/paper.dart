import 'package:flutter/material.dart';
import '../theme/oblix_theme.dart';

/// Small shared pieces of the "Paper" design language. Every screen composes
/// these instead of re-styling raw Material widgets.

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
    final label = Text(text.toUpperCase(), style: OblixType.eyebrow(c, color: color));
    return Padding(
      padding: padding,
      child: rule
          ? Row(children: [
              label,
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  height: 1,
                  color: (color ?? c.ink).withValues(alpha: 0.15),
                ),
              ),
            ])
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
    final body = padding != null ? Padding(padding: padding!, child: child) : child;
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
    return Material(
      color: filled ? c.accent : Colors.transparent,
      shape: StadiumBorder(
        side: filled ? BorderSide.none : BorderSide(color: c.accent, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
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
                style: OblixType.ui(c,
                    size: 12.5, weight: FontWeight.w600, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 36px circular icon button on a surfaceAlt disc (editor top bar, back
/// buttons on detail screens).
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
    final button = Material(
      color: c.surfaceAlt,
      shape: CircleBorder(side: BorderSide(color: c.hairline)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.47, color: c.ink),
        ),
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
    return Material(
      color: c.avatarBg,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: Text(
              initial,
              style: OblixType.ui(c,
                  size: size * 0.4, weight: FontWeight.w600, color: c.avatarInk),
            ),
          ),
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
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
