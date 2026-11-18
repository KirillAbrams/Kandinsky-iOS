#!/usr/bin/env python3
# Проверяет, как копия плана замеров айфона выбирает сборку выпуска и какие библиотеки оставляет.
# Все проверки работают со строками и не запускают приложение.

import copy, unittest
from pathlib import Path
from ios_release_driver import patch_driver


class DriverTest(unittest.TestCase):
    # Создаёт условное описание запуска с вложенным набором проверок и переданными библиотеками.
    # Так тест видит, какие части копии были заменены.
    def plan(self, injection):
        return {
            "Targets": [
                {
                    "UITargetAppPath": "__TESTROOT__/Debug-iphonesimulator/Kandinsky.app",
                    "UITargetAppEnvironmentVariables": {"DYLD_INSERT_LIBRARIES": injection},
                    "TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/KandinskyUITests.xctest",
                }
            ]
        }

    # Сравнивает исходное описание с копией до правки и проверяет оба выходных пути. Приложение
    # берётся из сборки выпуска, а тестовый набор остаётся отдельным.
    def test_release_paths_and_input_are_preserved(self):
        original = self.plan("/usr/lib/libRPAC.dylib")
        before = copy.deepcopy(original)
        actual = patch_driver(
            original, Path("/build/Release-iphonesimulator/Kandinsky.app"), Path("/build")
        )
        self.assertEqual(original, before)
        self.assertEqual(
            actual["Targets"][0]["UITargetAppPath"], "/build/Release-iphonesimulator/Kandinsky.app"
        )
        self.assertEqual(
            actual["Targets"][0]["TestBundlePath"],
            "/build/Debug-iphonesimulator/KandinskyUITests.xctest",
        )

    # Передаёт проверку главного потока вместе с другой библиотекой. Сравнение обнаружит как
    # оставшуюся проверку, так и удаление другой библиотеки.
    def test_removes_only_main_thread_checker(self):
        value = self.plan(
            "__SIMRUNTIMEROOT__/usr/lib/libMainThreadChecker.dylib:/usr/lib/libRPAC.dylib"
        )
        actual = patch_driver(value, Path("/release/Kandinsky.app"), Path("/build"))
        self.assertEqual(
            actual["Targets"][0]["UITargetAppEnvironmentVariables"]["DYLD_INSERT_LIBRARIES"],
            "/usr/lib/libRPAC.dylib",
        )

    # Подставляет три разных средства поиска ошибок и ждёт отказа. Сборку с такой нагрузкой нельзя
    # ошибочно считать обычной при замере.
    def test_rejects_sanitizer_injection(self):
        for name in ["asan", "tsan", "ubsan"]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                patch_driver(
                    self.plan("/usr/lib/libclang_rt." + name + "_iossim_dynamic.dylib"),
                    Path("/release/Kandinsky.app"),
                    Path("/build"),
                )


if __name__ == "__main__":
    unittest.main()
