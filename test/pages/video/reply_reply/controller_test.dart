import 'dart:io';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/reply/reply_sort_type.dart';
import 'package:PiliPlus/pages/video/reply_reply/controller.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _Controller extends VideoReplyReplyController {
  _Controller({super.rpid = 2, super.owner, super.removedReplies})
    : super(
        hasRoot: false,
        id: null,
        oid: 1,
        dialog: null,
        replyType: 1,
      );

  int requests = 0;

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    requests++;
  }
}

class _PagingController extends VideoReplyReplyController {
  _PagingController(this.responses)
    : super(
        hasRoot: false,
        id: null,
        oid: 1,
        rpid: 2,
        dialog: null,
        replyType: 1,
      );

  final List<LoadingState<DetailListReply>> responses;
  final requestedOffsets = <String?>[];

  @override
  Future<LoadingState<DetailListReply>> customGetData() async {
    requestedOffsets.add(nextOffset);
    return responses.removeAt(0);
  }
}

Success<DetailListReply> _page(
  List<int> ids, {
  required String offset,
  bool isEnd = false,
}) => Success(
  DetailListReply(
    root: ReplyInfo(
      id: Int64(2),
      count: Int64(10),
      replies: ids.map(
        (id) => ReplyInfo(id: Int64(id), parent: Int64(2), root: Int64(2)),
      ),
    ),
    cursor: CursorReply(isEnd: isEnd),
    paginationReply: FeedPaginationReply(nextOffset: offset),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-reply-test-');
    Hive.init(tempDir.path);
    GStorage.setting = await Hive.openBox('setting');
  });

  setUp(() => GStorage.setting.clear());

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('initializes once with the saved floor reply sort order', () async {
    await GStorage.setting.put(
      SettingBoxKey.reply2SortType,
      ReplySortType.time.index,
    );
    final controller = _Controller();
    addTearDown(controller.onClose);

    controller.onInit();

    expect(controller.sortType.value, ReplySortType.time);
    expect(controller.mode, Mode.MAIN_LIST_TIME);
    expect(controller.requests, 1);
  });

  test('subtree panels reuse owner data without requesting another floor', () {
    final owner = _Controller();
    final parent = ReplyInfo(id: Int64(3), parent: Int64(2), root: Int64(2));
    final reply = ReplyInfo(id: Int64(4), parent: Int64(3), root: Int64(2));
    final sibling = ReplyInfo(id: Int64(5), parent: Int64(2), root: Int64(2));
    owner.loadingState.value = Success([parent, reply, sibling]);
    final blocked = ReplyInfo(id: Int64(6), parent: Int64(4), root: Int64(2));
    final controller = _Controller(
      rpid: 3,
      owner: owner,
      removedReplies: {blocked.id: blocked},
    );
    addTearDown(owner.onClose);
    addTearDown(controller.onClose);

    controller.onInit();

    expect(controller.requests, 0);
    expect(controller.subtreeData, [reply]);
    expect(controller.blockedReplies[blocked.id], same(blocked));
  });

  test('folded replies coexist with tree collapse and refresh state', () async {
    final controller = _Controller();
    addTearDown(controller.onClose);
    controller.onInit();
    final fold = FoldCard(bottomText: '展开折叠评论');
    final response = Success(
      DetailListReply(
        root: ReplyInfo(id: Int64(2), count: Int64(5)),
        mixedCards: [MixedCard(type: MixedCard_Type.FOLD, fold: fold)],
      ),
    );
    controller.collapsedRpids.add(Int64(3));

    controller.customHandleResponse(false, response);

    expect(controller.foldCard, fold);
    expect(controller.collapsedRpids, contains(Int64(3)));

    controller.customHandleResponse(true, response);

    expect(controller.foldCard, fold);
    expect(controller.collapsedRpids, isEmpty);
    expect(controller.count.value, 5);

    controller.onLoadMoreError('加载失败');
    await controller.onRefresh();

    expect(controller.foldCard, isNull);
    expect(controller.loadMoreError.value, isNull);
  });

  test('floor completion follows offsets through empty reply pages', () async {
    final controller = _PagingController([
      _page([3], offset: 'page-2'),
      _page([], offset: 'page-3'),
      _page([4], offset: 'page-4'),
      _page([5], offset: '', isEnd: true),
    ]);
    addTearDown(controller.onClose);

    await controller.queryData();
    await controller.ensureFloorComplete();

    expect(controller.requestedOffsets, [null, 'page-2', 'page-3', 'page-4']);
    expect(
      controller.loadingState.value.data!.map((reply) => reply.id.toInt()),
      [
        3,
        4,
        5,
      ],
    );
    expect(controller.floorLoaded.value, 3);
    expect(controller.isFloorComplete, isTrue);
    expect(controller.isCompletingFloor.value, isFalse);
    expect(controller.loadMoreError.value, isNull);
  });

  test(
    'empty pagination offset ends loading even without cursor end',
    () async {
      final controller = _PagingController([
        _page([3], offset: ''),
      ]);
      addTearDown(controller.onClose);

      await controller.queryData();
      await controller.ensureFloorComplete();

      expect(controller.requestedOffsets, [null]);
      expect(controller.isFloorComplete, isTrue);
    },
  );

  test('refresh restarts pagination after a load-more failure', () async {
    final controller = _PagingController([
      _page([3], offset: 'page-2'),
      const Error('加载失败'),
      _page([6], offset: 'new-page-2'),
    ]);
    addTearDown(controller.onClose);

    await controller.queryData();
    await controller.onLoadMore();

    expect(controller.loadMoreError.value, '加载失败');
    expect(controller.nextOffset, 'page-2');
    expect(controller.loadingState.value.data!.single.id, Int64(3));

    await controller.onRefresh();

    expect(controller.requestedOffsets, [null, 'page-2', null]);
    expect(controller.nextOffset, 'new-page-2');
    expect(controller.loadingState.value.data!.single.id, Int64(6));
    expect(controller.loadMoreError.value, isNull);
  });
}
