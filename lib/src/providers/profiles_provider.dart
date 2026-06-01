import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/profile.dart';
import '../services/storage_service.dart';

const _uuid = Uuid();

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final profilesProvider =
    StateNotifierProvider<ProfilesNotifier, List<TrustTunnelProfile>>(
  (ref) => ProfilesNotifier(),
);

final selectedProfileIdProvider =
    StateNotifierProvider<SelectedProfileNotifier, String?>(
  (ref) => SelectedProfileNotifier(),
);

/// Convenience derived provider — resolves the selected ID to a full profile.
final selectedProfileProvider = Provider<TrustTunnelProfile?>((ref) {
  final id = ref.watch(selectedProfileIdProvider);
  if (id == null) return null;
  final profiles = ref.watch(profilesProvider);
  try {
    return profiles.firstWhere((p) => p.id == id);
  } catch (_) {
    return null;
  }
});

// ---------------------------------------------------------------------------
// ProfilesNotifier
// ---------------------------------------------------------------------------

class ProfilesNotifier extends StateNotifier<List<TrustTunnelProfile>> {
  ProfilesNotifier() : super(const []);

  /// Load the persisted profile list from storage.
  Future<void> loadFromStorage() async {
    final profiles = await StorageService.loadProfiles();
    state = profiles;
  }

  /// Append [profile] to the list, generating an id if one is not set.
  Future<void> addProfile(TrustTunnelProfile profile) async {
    final withId =
        profile.id.isEmpty ? profile.copyWith(id: _uuid.v4()) : profile;
    state = [...state, withId];
    await StorageService.saveProfiles(state);
  }

  /// Replace the profile whose [id] matches [profile.id].
  Future<void> updateProfile(TrustTunnelProfile profile) async {
    state = [
      for (final p in state)
        if (p.id == profile.id) profile else p,
    ];
    await StorageService.saveProfiles(state);
  }

  /// Remove the profile with the given [id].
  Future<void> deleteProfile(String id) async {
    state = state.where((p) => p.id != id).toList();
    await StorageService.saveProfiles(state);
  }

  /// Move the item at [oldIndex] to [newIndex].
  ///
  /// Mirrors the index semantics used by Flutter's [ReorderableListView]:
  /// [newIndex] is the position *before* the item is removed, so an
  /// adjustment of −1 is applied when [newIndex] > [oldIndex].
  Future<void> reorderProfiles(int oldIndex, int newIndex) async {
    final list = [...state];
    final item = list.removeAt(oldIndex);
    final insertIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
    list.insert(insertIndex, item);
    state = list;
    await StorageService.saveProfiles(state);
  }
}

// ---------------------------------------------------------------------------
// SelectedProfileNotifier
// ---------------------------------------------------------------------------

class SelectedProfileNotifier extends StateNotifier<String?> {
  SelectedProfileNotifier() : super(null);

  /// Restore the last-selected profile id from storage.
  Future<void> loadFromStorage() async {
    final id = await StorageService.loadSelectedProfileId();
    state = id;
  }

  /// Persist and apply a new selection (pass `null` to deselect).
  Future<void> select(String? id) async {
    state = id;
    await StorageService.saveSelectedProfileId(id);
  }
}
