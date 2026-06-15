import 'api_client.dart';

/// A Prodigi POD product from `GET /api/print/prodigi/products`.
class PrintProductDto {
  PrintProductDto({
    required this.key,
    required this.name,
    required this.type,
    required this.orientation,
    required this.aspect,
    required this.priceCents,
    required this.priceFormatted,
    required this.sellable,
  });

  final String key;
  final String name;
  final String type;
  final String orientation;
  final double aspect;
  final int priceCents;
  final String priceFormatted;
  final bool sellable;

  factory PrintProductDto.fromJson(Map<String, dynamic> j) => PrintProductDto(
        key: j['key'] as String,
        name: j['name'] as String? ?? '',
        type: j['type'] as String? ?? '',
        orientation: j['orientation'] as String? ?? '',
        aspect: (j['aspect'] as num?)?.toDouble() ?? 1,
        priceCents: (j['priceCents'] as num?)?.toInt() ?? 0,
        priceFormatted: j['priceFormatted'] as String? ?? '',
        sellable: j['sellable'] as bool? ?? false,
      );
}

/// A placed print order from `GET /api/print/prodigi/orders`.
class PrintOrderDto {
  PrintOrderDto({
    required this.id,
    required this.productName,
    required this.status,
    required this.totalFormatted,
    this.productKey,
    this.attributes,
    this.thumbnailUrl,
    this.prodigiStatus,
    this.prodigiOrderId,
    this.errorMessage,
    this.trackingNumber,
    this.trackingUrl,
    this.createdAt,
  });

  final String id;
  final String productName;
  final String status;
  final String totalFormatted;
  final String? productKey;
  final Map<String, String>? attributes;
  final String? thumbnailUrl;
  final String? prodigiStatus;
  final String? prodigiOrderId;
  final String? errorMessage;
  final String? trackingNumber;
  final String? trackingUrl;
  final String? createdAt;

  /// Paid but not yet handed to Prodigi — can be re-submitted (resumed).
  bool get isResumable =>
      prodigiOrderId == null &&
      (status == 'paid' ||
          status == 'uploading' ||
          status == 'submitted' ||
          status == 'failed');

  /// Human-readable option line, e.g. "Image wrap" / "Black frame" / "Lustre".
  String? get optionSummary {
    final a = attributes;
    if (a == null || a.isEmpty) return null;
    final parts = <String>[];
    for (final e in a.entries) {
      switch (e.key) {
        case 'wrap':
          parts.add(switch (e.value) {
            'ImageWrap' => 'Image wrap',
            'MirrorWrap' => 'Mirror wrap',
            'Black' => 'Black edges',
            'White' => 'White edges',
            _ => e.value,
          });
        case 'color':
          parts.add('${_cap(e.value)} frame');
        case 'finish':
          parts.add('${_cap(e.value)} finish');
        default:
          parts.add('${e.key}: ${e.value}');
      }
    }
    return parts.join(' · ');
  }

  static String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  factory PrintOrderDto.fromJson(Map<String, dynamic> j) => PrintOrderDto(
        id: j['id'] as String,
        productName: j['productName'] as String? ?? 'Print',
        status: j['status'] as String? ?? 'pending',
        totalFormatted: j['totalFormatted'] as String? ?? '',
        productKey: j['productKey'] as String?,
        attributes: (j['attributes'] as Map?)
            ?.map((k, v) => MapEntry(k.toString(), v.toString())),
        thumbnailUrl: j['thumbnailUrl'] as String?,
        prodigiStatus: j['prodigiStatus'] as String?,
        prodigiOrderId: j['prodigiOrderId'] as String?,
        errorMessage: j['errorMessage'] as String?,
        trackingNumber: j['trackingNumber'] as String?,
        trackingUrl: j['trackingUrl'] as String?,
        createdAt: j['createdAt']?.toString(),
      );
}

/// Shipping recipient for a print order.
class PrintRecipient {
  PrintRecipient({
    required this.name,
    required this.email,
    required this.address1,
    required this.city,
    required this.countryCode,
    required this.zip,
    this.phone,
    this.address2,
    this.stateCode,
  });

  final String name;
  final String email;
  final String address1;
  final String city;
  final String countryCode;
  final String zip;
  final String? phone;
  final String? address2;
  final String? stateCode;

  Map<String, dynamic> toJson() => {
        'name': name,
        'email': email,
        'address1': address1,
        if (address2 != null && address2!.isNotEmpty) 'address2': address2,
        'city': city,
        if (stateCode != null && stateCode!.isNotEmpty) 'stateCode': stateCode,
        'countryCode': countryCode,
        'zip': zip,
        if (phone != null && phone!.isNotEmpty) 'phone': phone,
      };
}

/// Normalised crop rect (0..1) over the rendered mosaic.
class PrintCrop {
  PrintCrop(this.left, this.top, this.width, this.height);
  final double left, top, width, height;
  Map<String, dynamic> toJson() =>
      {'left': left, 'top': top, 'width': width, 'height': height};
}

class CheckoutSession {
  CheckoutSession(this.checkoutUrl, this.orderId);
  final String checkoutUrl;
  final String orderId;
}

/// Prodigi print-on-demand client. Talks to the new `/api/print/prodigi/*`
/// endpoints (independent of the web's Printful flow).
class PrintApi {
  PrintApi(this._client);
  final ApiClient _client;

  Future<ApiResult<List<PrintProductDto>>> products() async {
    final res =
        await _client.get<Map<String, dynamic>>('/api/print/prodigi/products');
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Could not load products.', res.status);
    }
    final list = (res.data!['products'] as List? ?? [])
        .map((e) => PrintProductDto.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    return ApiResult.ok(list, res.status);
  }

  Future<ApiResult<CheckoutSession>> checkout({
    required String productKey,
    required String sessionId,
    required Map<String, dynamic> plan,
    required Map<String, String> tileUrls,
    required String baseUrl,
    required PrintCrop cropRect,
    required PrintRecipient recipient,
    Map<String, String>? attributes,
  }) async {
    final res = await _client.post<Map<String, dynamic>>(
      '/api/print/prodigi/checkout',
      body: {
        'productKey': productKey,
        'sessionId': sessionId,
        'plan': plan,
        'tileUrls': tileUrls,
        'baseUrl': baseUrl,
        'cropRect': cropRect.toJson(),
        'recipient': recipient.toJson(),
        'attributes': ?attributes,
      },
    );
    if (!res.isOk || res.data == null || res.data!['checkout_url'] == null) {
      return ApiResult.fail(
          res.error ?? (res.data?['error'] as String?) ?? 'Checkout failed.',
          res.status);
    }
    return ApiResult.ok(
      CheckoutSession(
          res.data!['checkout_url'] as String, res.data!['orderId'] as String),
      res.status,
    );
  }

  Future<ApiResult<String>> fulfill(String orderId) async {
    final res = await _client.post<Map<String, dynamic>>(
        '/api/print/prodigi/fulfill',
        body: {'orderId': orderId});
    if (!res.isOk || res.data == null || res.data!['success'] != true) {
      return ApiResult.fail(
          res.error ?? (res.data?['error'] as String?) ?? 'Fulfilment failed.',
          res.status);
    }
    return ApiResult.ok(res.data!['prodigiOrderId'] as String? ?? '', res.status);
  }

  Future<ApiResult<List<PrintOrderDto>>> orders() async {
    final res =
        await _client.get<Map<String, dynamic>>('/api/print/prodigi/orders');
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Could not load orders.', res.status);
    }
    final list = (res.data!['orders'] as List? ?? [])
        .map((e) => PrintOrderDto.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    return ApiResult.ok(list, res.status);
  }
}
