# Кандинский для айфона

Приложение показывает историю, отправляет задания на создание фото и видео и открывает готовые результаты

Чаты синхронизируются с сервером, черновик и место чтения сохраняются на телефоне

## Как открыть

На Маке установи **Xcode** и запусти один симулятор айфона. Из корня скачанного проекта выполни одну команду. Она соберёт приложение, установит его и откроет на симуляторе.

```sh
xcodebuild -project ios/Kandinsky.xcodeproj -scheme Kandinsky -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build && \
  xcrun simctl install "${KANDINSKY_SIMULATOR:-booted}" DerivedData/Build/Products/Release-iphonesimulator/Kandinsky.app && \
  xcrun simctl launch "${KANDINSKY_SIMULATOR:-booted}" dev.kirill.kandinsky.native
```

При нескольких запущенных симуляторах укажи нужный через **KANDINSKY_SIMULATOR**. Идентификатор можно посмотреть в списке **xcrun simctl list devices booted**.

Для установки на айфон открой [проект приложения](ios/Kandinsky.xcodeproj) в Xcode, выбери схему **Kandinsky**, свой телефон и команду подписи. Приложение поддерживает систему версии 16 и новее.

По умолчанию приложение подключается к рабочему серверу в Алматы. Для регистрации понадобится почта, на которую придёт код. После входа можно открыть «Плотную медиаленту» и «Длинную историю». Для своих генераций создай новый чат.

Адрес своего сервера можно передать через **KANDINSKY_BRIDGE_ORIGIN** при сборке. Нужен защищённый адрес с действующим сертификатом.

## Карта проекта

| Папка или файл | Что внутри |
| --- | --- |
| [Config](ios/Config) | Настройки приложения и разрешения системы |
| [Resources](ios/Resources) | Значки и описание работы с личными данными |
| [App](ios/Sources/App) | Запуск приложения и подключение служб аккаунта |
| [Account](ios/Sources/Account) | Экраны входа, регистрации и восстановления пароля |
| [Attachments](ios/Sources/Attachments) | Камера, выбор и отправка исходника |
| [ChatList](ios/Sources/ChatList) | Список чатов, архив, поиск и закрепление |
| [ConversationState.swift](ios/Sources/Conversation/ConversationState.swift) | Состояние разговора и правила отправки или повтора |
| [Network](ios/Sources/Network) | Связь с сервером, очередь команд и сохранение событий |
| [Storage](ios/Sources/Storage) | База на телефоне, черновики и изменения таблиц |
| [Rendering](ios/Sources/Rendering) | Прокрутка, страницы истории и сохранение видимой строки |
| [Media](ios/Sources/Media) | Подготовка файлов, изображений и видео |
| [VideoCoverDiskCache.swift](ios/Sources/Media/VideoCoverDiskCache.swift) | Хранение чётких кадров для повторного показа |
| [Results](ios/Sources/Results) | Просмотр фото и видео на весь экран |
| [Tests](ios/Tests) и [UITests](ios/UITests) | Проверки правил, хранения данных и действий на экране |
| [fixtures](fixtures) | Фото, видео и ожидаемые результаты для тестов |

## Проверки и выпуск

В среде сборки выбери схему **Kandinsky** и запусти тесты на симуляторе

Для проверок с сетью подключи отдельный стенд с временными данными

Команда для проверки выпускного архива без подписи

    xcodebuild -project ios/Kandinsky.xcodeproj -scheme Kandinsky -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/Kandinsky-iOS.xcarchive CODE_SIGNING_ALLOWED=NO EXCLUDED_SOURCE_FILE_NAMES=fixtures archive

Для установки и выпуска подпиши сборку своей командой разработчика

Файлы для тестов хранятся отдельно от выпускного приложения

## Материалы для проверок

В [перечне файлов](fixtures/real-media/manifest.json) есть авторы, источники, условия использования и контрольные суммы

[Малая копия файла](fixtures/real-media/cached-preview-source.json) описана отдельно

- [Описание большого набора](fixtures/manifest.json) перечисляет каждый файл, его вид, размер и контрольную сумму. По нему проверка замечает подмену или потерю вложения.
- [Исходная тестовая история](fixtures/seed-v1.json) задаёт десять тысяч сообщений, их порядок, подписи и ссылки на файлы.
- [Снимки, ролики и звуковые файлы для проверок](fixtures/media) используются при местной проверке чтения истории. Каждый файл описан в перечне большого набора.
- [Малые копии и форма звука](fixtures/media-previews-v1.json) заполняют местный справочник для показа перед открытием оригинала.
- [Ожидаемые результаты операций с историей](fixtures/oracles/history-operations-v1.json) позволяют сверить порядок строк на обеих платформах с заранее рассчитанным ответом.
- [Подборка для проверки места на диске](fixtures/real-media/cache-working-set.json) задаёт исходники для проверки уборки и предела хранения.
- [Очень маленькие копии для проверок](fixtures/real-media/tiny-preview-probe.json) дают исходные данные для сравнения раскодирования и повторного показа.
- [Образцы для проверки текста](fixtures/real-media/text-raster-samples.json) помогают сопоставить границы текста и его изображение при отрисовке ленты.
- [Перечень движущихся картинок](fixtures/catalogue-media/catalogue.json) описывает три файла рядом. Они позволяют проверить, как окно просмотра работает с таким вложением.

## Значки приложения

Версия каталога указана в [общем описании значков](ios/Resources/Assets.xcassets/Contents.json). В каждой папке описание указывает сборке, какой рисунок использовать. [Разрешение на использование значков](ios/Resources/Heroicons-LICENSE.txt) входит в приложение.

| Назначение | Файл или папка |
| --- | --- |
| Значок установленного приложения | [Значок](ios/Resources/Assets.xcassets/AppIcon.appiconset) |
| Снять фото | [Камера](ios/Resources/Assets.xcassets/KandinskyAttachmentCamera.imageset) |
| Выбрать снимок для запроса | [Снимок](ios/Resources/Assets.xcassets/KandinskyAttachmentPhoto.imageset) |
| Начать новый чат | [Добавить](ios/Resources/Assets.xcassets/KandinskyDrawerAdd.imageset) |
| Открыть архив | [Архив](ios/Resources/Assets.xcassets/KandinskyDrawerArchive.imageset) |
| Вернуться из архива | [Назад](ios/Resources/Assets.xcassets/KandinskyDrawerBack.imageset) |
| Выйти из аккаунта | [Выход](ios/Resources/Assets.xcassets/KandinskyDrawerLogout.imageset) |
| Открыть действия чата или аккаунта | [Действия](ios/Resources/Assets.xcassets/KandinskyDrawerMore.imageset) |
| Найти чат по названию | [Поиск](ios/Resources/Assets.xcassets/KandinskyDrawerSearch.imageset) |
| Узор за сообщениями в чате | [Знак](ios/Resources/Assets.xcassets/KandinskyEvolution.imageset) |
| Развернуть просмотр | [Развернуть](ios/Resources/Assets.xcassets/KandinskyExpand.imageset) |
| Повторить генерацию | [Повтор](ios/Resources/Assets.xcassets/KandinskyGenerationRefresh.imageset) |
| Отметить выбранную модель | [Отметка](ios/Resources/Assets.xcassets/KandinskyModelCheck.imageset) |
| Обозначить модель видео | [Видео](ios/Resources/Assets.xcassets/KandinskyModelVideo.imageset) |
| Открыть недавний ролик | [Ролик](ios/Resources/Assets.xcassets/KandinskyRecentVideo.imageset) |
| Сохранить результат | [Сохранить](ios/Resources/Assets.xcassets/KandinskySave.imageset) |
| Передать результат другому приложению | [Поделиться](ios/Resources/Assets.xcassets/KandinskyShare.imageset) |
| Вернуться из полного просмотра загруженного видео | [Закрыть просмотр](ios/Resources/Assets.xcassets/KandinskyUploadClose.imageset) |
| Отметить закреплённый чат | [Скрепка](ios/Resources/Assets.xcassets/HeroiconsPaperClip.imageset) |

## Связанные части проекта

- [Сервер Кандинского](https://github.com/KirillAbrams/Kandinsky-Backend)
- [Приложение для Андроида](https://github.com/KirillAbrams/Kandinsky-Android)
