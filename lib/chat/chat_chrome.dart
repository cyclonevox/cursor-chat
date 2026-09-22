import 'package:flutter/material.dart';

import '../models/models.dart';
import '../store.dart';

String modeLabel(Conversation? conv) =>
    conv?.kind == ConversationKind.isolated ? '独立 Agent' : '快速对话';

String? appBarModeLine(Conversation? conv, ChatStore store) {
  final mode = modeLabel(conv);
  final model = store.models.isNotEmpty ? store.modelSummary : null;
  if (conv?.title == mode) return model;
  if (model == null) return mode;
  return '$mode · $model';
}

/// Title plus the mode line. A fixed 56px bar clips that second line on a phone,
/// and the error banner then starts on top of it.
double chatBarHeight(BuildContext context, {required bool twoLine}) {
  if (!twoLine) return kToolbarHeight;
  final scaled = MediaQuery.textScalerOf(context).scale(72);
  return scaled < kToolbarHeight ? kToolbarHeight : scaled;
}
