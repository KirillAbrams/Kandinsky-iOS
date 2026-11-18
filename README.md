# Кандинский для айфона

Приложение показывает историю, отправляет задания на создание фото и видео и открывает готовые результаты

Чаты синхронизируются с сервером, черновик и место чтения сохраняются на телефоне

## Как открыть

Открой [проект приложения](ios/Kandinsky.xcodeproj) в **Xcode**

Выбери схему **Kandinsky** и симулятор

Для установки на айфон выбери свой телефон и команду подписи

Приложение поддерживает систему версии 16 и новее

Адрес своего сервера можно передать через **KANDINSKY_BRIDGE_ORIGIN**

Для подключения нужен защищённый адрес службы связи с действующим сертификатом

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

## Связанные части проекта

- [Сервер Кандинского](https://github.com/KirillAbrams/Kandinsky-Backend)
- [Приложение для Андроида](https://github.com/KirillAbrams/Kandinsky-Android)

Общий снимок исходников проекта **6572430db4f48ca89ebcf9ba0b1330f9808786ff**
