import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/dependencies.dart';
import 'core/config/app_config.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  final problem = config.problem;
  runApp(
    problem != null
        ? ConfigErrorApp(problem: problem)
        : LeopardApp(dependencies: AppDependencies.production(config)),
  );
}
