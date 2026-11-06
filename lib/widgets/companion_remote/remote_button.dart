import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_icon.dart';

/// A round remote button with its label underneath: the phone remote's
/// transport and volume rows, and the Reel's On TV mode (fork, V2-49).
/// A null [onPressed] shows it disabled.
class RemoteButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;

  const RemoteButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.size = 56,
    this.iconSize = 24,
  });

  @override
  Widget build(BuildContext context) {
    final onPressed = this.onPressed;
    return Column(
      mainAxisSize: .min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: FilledButton(
            onPressed: onPressed == null
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    onPressed();
                  },
            style: FilledButton.styleFrom(padding: .zero, shape: const CircleBorder()),
            child: AppIcon(icon, size: iconSize),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
      ],
    );
  }
}
