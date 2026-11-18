# Готовит копию плана измерения для сборки выпуска айфона. Указывает собранное приложение,
# сохраняя обычный набор проверок и настройки проекта.

"""Prepare only the generated performance driver, without changing app/test schemes."""


# Убирает только проверку главного потока из списка загружаемых библиотек. Если находит
# измерительные средства поиска ошибок памяти или потоков, прекращает подготовку, чтобы не смешать
# разные условия.
def clean_injection(value):
    libraries = value.split(":")
    if any(
        "libclang_rt." in item and any(name in item for name in ["asan", "tsan", "ubsan"])
        for item in libraries
    ):
        raise ValueError("Release performance driver contains sanitizer injection")
    return ":".join(item for item in libraries if "libMainThreadChecker.dylib" not in item)


# Рекурсивно заменяет путь к запускаемому приложению и раскрывает относительные пути к результатам
# сборки. Исходное описание остаётся пригодным для обычных тестов.
def patch_driver(value, release, products):
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key == "UITargetAppPath":
                result[key] = str(release)
            elif key == "DYLD_INSERT_LIBRARIES" and isinstance(item, str):
                result[key] = clean_injection(item)
            else:
                result[key] = patch_driver(item, release, products)
        return result
    if isinstance(value, list):
        return [patch_driver(item, release, products) for item in value]
    if isinstance(value, str):
        if value.endswith("/Debug-iphonesimulator/Kandinsky.app"):
            return str(release)
        return value.replace("__TESTROOT__", str(products))
    return value
