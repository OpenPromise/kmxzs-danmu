import 'dart:io';

import 'package:dio/io.dart';
import 'package:kmxzs/services/cert_pinning.dart';

/// 统一的 dart:io HttpClient 工厂：所有 HTTP(S) 出口（API、下载安装包）都走
/// 证书绑定，防止中间人用任意证书替换服务器。
abstract final class HttpClientFactory {
  static HttpClient create() {
    final client = HttpClient();
    client.badCertificateCallback = CertPinner.accept;
    return client;
  }

  /// dio 适配器：让 Dio 使用带证书绑定的底层 HttpClient。
  static IOHttpClientAdapter dioAdapter() =>
      IOHttpClientAdapter(createHttpClient: create);
}
