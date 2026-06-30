import '../models/collection.dart';
import 'api_client.dart';

class CollectionService {
  Future<List<Collection>> fetchCollections() async {
    try {
      final res = await ApiClient.get('/collections.php');
      final data = res.data;
      if (data is Map<String, dynamic>) {
        final list = data['collections'] ?? [];
        if (list is List) {
          return list
              .map((e) => Collection.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      }
      return getDefaultCollections();
    } catch (e) {
      return getDefaultCollections();
    }
  }

  List<Collection> getDefaultCollections() {
    return const [
      Collection(id: 1, name: 'Châu Tinh Trì', slug: 'chau-tinh-tri', count: 42, gradient: ['#8B5CF6', '#EC4899']),
      Collection(id: 2, name: 'Marvel', slug: 'marvel', count: 35, gradient: ['#DC2626', '#F97316']),
      Collection(id: 3, name: 'DC Comic', slug: 'dc-comic', count: 28, gradient: ['#2563EB', '#7C3AED']),
      Collection(id: 4, name: 'Doraemon', slug: 'doraemon', count: 20, gradient: ['#0891B2', '#10B981']),
      Collection(id: 5, name: 'Anime HOT', slug: 'anime-hot', count: 150, gradient: ['#DB2777', '#9333EA']),
      Collection(id: 6, name: 'Hoạt Hình', slug: 'hoat-hinh', count: 89, gradient: ['#059669', '#0D9488']),
    ];
  }
}
