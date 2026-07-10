class AppConfig {
  static String get baseUrl => 'https://xiaofilm.site';
  static String get apiUrl  => 'https://xiaofilm.site/api';
  static const int connectTimeout = 15000;
  static const int receiveTimeout = 15000;

  static String proxyHlsUrl(String url) {
    return '$apiUrl/hls_proxy.php?url=${Uri.encodeComponent(url)}';
  }

  static String proxyHlsFullUrl(String url) {
    return '$apiUrl/hls_proxy.php?url=${Uri.encodeComponent(url)}&full=1';
  }

  static String get serverHealthUrl => '$apiUrl/server_health.php';
}
