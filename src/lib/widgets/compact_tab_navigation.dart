import 'package:flutter/material.dart';

/// A page entry used by the compact Android navigation bar and its overflow
/// menu. [id] is the stable internal tab name; [title] is localized UI text.
class CompactTabDestination {
  const CompactTabDestination({
    required this.id,
    required this.title,
    required this.assetPath,
    required this.fallbackIcon,
  });

  final String id;
  final String title;
  final String assetPath;
  final IconData fallbackIcon;
}

/// Keeps the most-used pages visible on a phone while leaving every other page
/// one tap away in a scrollable More sheet.
class CompactTabNavigation extends StatelessWidget {
  const CompactTabNavigation({
    super.key,
    required this.primaryDestinations,
    required this.moreDestinations,
    required this.currentId,
    required this.moreTitle,
    required this.onSelect,
  });

  final List<CompactTabDestination> primaryDestinations;
  final List<CompactTabDestination> moreDestinations;
  final String currentId;
  final String moreTitle;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final selectedPrimary = primaryDestinations.indexWhere(
      (destination) => destination.id == currentId,
    );
    final selectedIndex = selectedPrimary < 0
        ? primaryDestinations.length
        : selectedPrimary;

    return NavigationBar(
      key: const ValueKey('main_tab_navigation'),
      height: 72,
      selectedIndex: selectedIndex,
      onDestinationSelected: (index) {
        if (index == primaryDestinations.length) {
          _showMore(context);
          return;
        }
        onSelect(primaryDestinations[index].id);
      },
      destinations: [
        for (final destination in primaryDestinations)
          NavigationDestination(
            key: ValueKey('main_tab_${destination.id}'),
            icon: _destinationIcon(destination),
            selectedIcon: _destinationIcon(destination, selected: true),
            label: destination.title,
            tooltip: destination.title,
          ),
        NavigationDestination(
          key: const ValueKey('main_tab_more'),
          icon: const Icon(Icons.more_horiz),
          selectedIcon: const Icon(Icons.more_horiz),
          label: moreTitle,
          tooltip: moreTitle,
        ),
      ],
    );
  }

  Widget _destinationIcon(
    CompactTabDestination destination, {
    bool selected = false,
  }) {
    return Image.asset(
      destination.assetPath,
      width: 24,
      height: 24,
      errorBuilder: (context, error, stackTrace) => Icon(
        destination.fallbackIcon,
        size: 24,
        color: selected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Future<void> _showMore(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.75;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView(
              key: const ValueKey('compact_more_list'),
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Text(
                    moreTitle,
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                ),
                for (final destination in moreDestinations)
                  ListTile(
                    key: ValueKey('compact_more_${destination.id}'),
                    leading: _destinationIcon(
                      destination,
                      selected: destination.id == currentId,
                    ),
                    title: Text(destination.title),
                    selected: destination.id == currentId,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onSelect(destination.id);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
