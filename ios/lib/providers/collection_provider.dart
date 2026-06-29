import 'package:flutter/foundation.dart';
import '../models/collection.dart';
import '../services/collection_service.dart';

class CollectionProvider extends ChangeNotifier {
  final CollectionService _service = CollectionService();

  List<Collection> _collections = [];
  bool _isLoading = false;

  List<Collection> get collections => _collections;
  bool get isLoading => _isLoading;

  Future<void> fetchCollections() async {
    _isLoading = true;
    notifyListeners();

    try {
      _collections = await _service.fetchCollections();
    } catch (e) {
      _collections = _service.getDefaultCollections();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
