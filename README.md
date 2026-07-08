# S3 Testing Scripts

Набор bash-скриптов для полуавтоматического тестирования S3-совместимого API: проверка доступности, базовых операций, multipart upload, пределов размера объекта, массовой загрузки и очистки тестового стенда.

Данный набор скриптов не претендует на какую-либо полноту. Это просто удобные инструменты, которые я использую в работе.

Скрипты рассчитаны на запуск из этой директории. Если endpoint не указан явно, большинство скриптов используют `http://192.168.10.81`. Все обращения к S3 выполняются через AWS CLI с `--no-verify-ssl`, поэтому набор ориентирован на тестовые стенды и self-signed TLS.

## Quick Start

```bash
# Проверить доступность endpoint
./check_connection.sh http://192.168.10.81

# Проверить базовые S3-операции
./base_check.sh http://192.168.10.81

# Запустить полный набор API-проверок
./spec_methods_tester.sh -e http://192.168.10.81 -v -c

# Проверить multipart upload одного объекта
./multipart_upload_check.sh --bucket test-bucket --size 1gb --part 128mb --cleanup

# Найти максимальный размер single PUT
./max_object_size_probe.sh --bucket test-bucket --min 1mb --max 100mb --step 5mb --cleanup

# Прогнать диапазон multipart-загрузок
./max_object_multipart_probe.sh --bucket test-bucket --min 100mb --max 1gb --step 100mb --cleanup

# Загрузить много объектов одинакового размера
./put_bunch_objects.sh --bucket test-bucket --size 10mb --count 100 --unique 5 --cleanup

# Проверить ranged GetObject, включая объект из multipart upload
./range_get_check.sh --bucket test-bucket --size 40mb --multipart --gets 100 --cleanup
```

## Prerequisites

Общие требования:

- `bash`
- `aws` CLI в `PATH`
- настроенные AWS credentials: `AWS_ACCESS_KEY_ID` и `AWS_SECRET_ACCESS_KEY`, либо `~/.aws/credentials`
- сетевой доступ до S3 endpoint
- права на создание/удаление bucket, object, tags, versioning и multipart upload для соответствующих проверок
- достаточно свободного места локально для генерации тестовых файлов

Дополнительные утилиты, используемые отдельными скриптами:

- `jq`, `split`, `md5sum`, GNU `stat`, `dd`, `cat` для `spec_methods_tester.sh`
- `dd`, `md5sum`, `awk`, `grep -P`, `xxd`, `head`, `tr` для multipart-скриптов
- `dd`, `awk`, `head`, `tr` для bulk/size probe скриптов; GNU `stat` нужен для `max_object_size_probe.sh`; `md5sum` и `mktemp` дополнительно нужны при использовании `--check`
- `dd` (с поддержкой `iflag=skip_bytes,count_bytes`), GNU `stat`, `cmp`, `od`, `awk`, `grep -P`, `tr`, `jq` для `range_get_check.sh`

Пример настройки credentials:

```bash
aws configure set aws_access_key_id <ACCESS_KEY>
aws configure set aws_secret_access_key <SECRET_KEY>
aws configure set default.region us-east-1
aws configure set default.output json
```

## Script Matrix

| Script                          | Endpoint                   | Bucket                          | Debug     | Cleanup                                                                            | Size units                                                  |
| ------------------------------- | -------------------------- | ------------------------------- | --------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `check_connection.sh`           | positional, default есть   | не нужен                        | нет       | нет                                                                                | нет                                                         |
| `base_check.sh`                 | positional, default есть   | фиксированные test bucket names | нет       | automatic trap                                                                     | нет                                                         |
| `spec_methods_tester.sh`        | `-e`, required             | авто: `s3-api-test-<timestamp>` | `-v`      | automatic trap                                                                     | internal 1KB/10MB/50MB                                      |
| `test_multipart.sh`             | hard-coded                 | hard-coded `test-bucket`        | нет       | abort multipart only                                                               | нет                                                         |
| `multipart_upload_check.sh`     | `--endpoint`, default есть | `--bucket`, creates if missing  | `--debug` | `--cleanup` for object, trap for temp/uploads                                      | `mb`, `gb`, `tb`                                            |
| `max_object_size_probe.sh`      | `--endpoint`, default есть | `--bucket`, creates if missing  | нет       | `--cleanup`                                                                        | `kb`, `mb`, `gb`                                            |
| `max_object_multipart_probe.sh` | `--endpoint`, default есть | `--bucket`, creates if missing  | `--debug` | `--cleanup`                                                                        | `mb`, `gb`, `tb`                                            |
| `put_bunch_objects.sh`          | `--endpoint`, default есть | `--bucket`, creates if missing  | `--debug` | `--cleanup` for S3 objects, trap for local templates                               | `kb`, `mb`, `gb`                                            |
| `range_get_check.sh`            | `--endpoint`, default есть | `--bucket`, creates if missing  | `--debug` | `--cleanup` for the object, trap for temp files/parts, abort for multipart uploads | `mb`, `gb` for `--size`; `kb`, `mb`, `gb` for `--range-max` |
| `cleanup_all.sh`                | positional, default есть   | all buckets on endpoint         | нет       | destructive by design                                                              | нет                                                         |

## Connectivity and Compatibility

### `check_connection.sh`

Минимальная проверка доступности S3 endpoint через `list-buckets`.

```bash
./check_connection.sh [endpoint-url]
```

Example:

```bash
./check_connection.sh http://192.168.10.81
```

Если endpoint не указан, используется `http://192.168.10.81`.

### `base_check.sh`

Базовый compatibility smoke test без multipart upload. Скрипт использует фиксированные имена bucket:

- `new-bucket`
- `versioned-bucket`
- `bucket-for-tag`
- `bucket-for-attrs`
- `bucket-for-delete`

```bash
./base_check.sh [endpoint-url]
```

Проверяет:

- create/list/head/delete bucket
- put/head/get/copy/delete object
- `aws s3 sync`
- `list-objects` и `list-objects-v2`
- bucket versioning и `list-object-versions`
- bucket/object tagging
- базовый `get-object-attributes` для `ETag`, `ObjectSize`, `StorageClass`

На выходе запускает cleanup trap. Подробнее см. `base_check.md`.

### `spec_methods_tester.sh`

Наиболее полный сценарий проверки S3 API. Endpoint обязателен.

```bash
./spec_methods_tester.sh -e ENDPOINT_URL [-c] [-v] [-h]
```

Options:

- `-e ENDPOINT_URL`: S3 endpoint URL, например `http://192.168.10.81`
- `-c`: продолжать после non-critical ошибок
- `-v`: verbose output с API-вызовами
- `-h`: help

Example:

```bash
./spec_methods_tester.sh -e http://192.168.10.81 -v -c
```

Скрипт создает временный bucket `s3-api-test-<timestamp>` и рабочую директорию `/tmp/s3-test-<timestamp>`, пишет `test-results.log` и `timing.log`, затем удаляет созданные ресурсы.

Покрытие:

- bucket operations: `CreateBucket`, `HeadBucket`, `ListBuckets`, `DeleteBucket`
- bucket versioning: `PutBucketVersioning`, `GetBucketVersioning`
- bucket tagging: `PutBucketTagging`, `GetBucketTagging`, `DeleteBucketTagging`
- object operations: `PutObject`, `HeadObject`, `GetObject`, `CopyObject`
- object versioning: upload multiple versions, get by version id
- object tagging: `PutObjectTagging`, `GetObjectTagging`, `DeleteObjectTagging`
- multipart: `CreateMultipartUpload`, `ListMultipartUploads`, `UploadPart`, `ListParts`, `CompleteMultipartUpload`, `AbortMultipartUpload`
- delete operations: `DeleteObject`, `DeleteObjects`
- integrity check через `md5sum`

## Multipart Upload Testing

### `test_multipart.sh`

Очень короткая диагностическая проверка `CreateMultipartUpload` и `AbortMultipartUpload`.

```bash
./test_multipart.sh --bucket <bucket-name> [--endpoint <url>]
```

Скрипт принимает bucket обязательным параметром. Endpoint можно указать явно, иначе используется default:

- `--bucket <name>`: существующий bucket
- `--endpoint <url>`: default `http://192.168.10.81`
- key: `test-multipart-object.bin`

Bucket должен существовать заранее. Скрипт не загружает parts и не создает объект, он только инициирует multipart upload и abort-ит его.

### `multipart_upload_check.sh`

Загружает один объект через multipart upload и проверяет результат.

```bash
./multipart_upload_check.sh --bucket <bucket-name> --size <size> --part <size> [options]
```

Required:

- `--bucket <name>`: bucket name, будет создан при отсутствии
- `--size <size>`: размер объекта, например `100mb`, `1gb`, `5tb`
- `--part <size>`: размер part, например `64mb`, `128mb`

Options:

- `--endpoint <url>`: default `http://192.168.10.81`
- `--verify-full`: скачать объект после загрузки и сравнить MD5
- `--cleanup`: удалить загруженный S3 object после проверки
- `--debug`: печатать AWS CLI команды и ответы
- `-h`, `--help`: help

Examples:

```bash
./multipart_upload_check.sh --bucket test-bucket --size 500mb --part 64mb
./multipart_upload_check.sh --bucket test-bucket --size 1gb --part 128mb --verify-full --cleanup
./multipart_upload_check.sh --bucket test-bucket --size 100mb --part 64mb --debug
```

Режимы проверки:

- default hybrid: сравнивает рассчитанный multipart ETag с ETag, который вернул S3
- `--verify-full`: дополнительно скачивает объект и сравнивает MD5 исходного и скачанного файла

Временные файлы создаются в `/tmp` и удаляются через trap. Незавершенные multipart uploads abort-ятся при выходе.

### `max_object_multipart_probe.sh`

Проверяет диапазон размеров объектов через multipart upload и останавливается на первой неуспешной загрузке.

```bash
./max_object_multipart_probe.sh --bucket <bucket-name> --min <size> --max <size> --step <size> [options]
```

Required:

- `--bucket <name>`: bucket name, будет создан при отсутствии
- `--min <size>`: минимум, не меньше `100mb`
- `--max <size>`: максимум
- `--step <size>`: шаг

Options:

- `--endpoint <url>`: default `http://192.168.10.81`
- `--cleanup`: удалить успешно загруженные объекты
- `--debug`: печатать AWS CLI команды и ответы
- `-h`, `--help`: help

Size units: `mb`, `gb`, `tb`.

Part size выбирается автоматически:

- object `< 1gb`: `64mb`
- object `< 10gb`: `128mb`
- object `< 100gb`: `256mb`
- object `< 500gb`: `512mb`
- object `< 1tb`: `1024mb`
- object `< 5tb`: `2048mb`
- object `>= 5tb`: `4096mb`

Examples:

```bash
./max_object_multipart_probe.sh --bucket test-bucket --min 100mb --max 1gb --step 100mb --cleanup
./max_object_multipart_probe.sh --bucket test-bucket --min 1gb --max 10tb --step 1gb --debug
```

## Object Size and Bulk Upload

### `max_object_size_probe.sh`

Проверяет максимальный размер объекта для single PUT (`put-object`) без multipart upload. Диапазон задается явно, значений по умолчанию для `--min`, `--max`, `--step` нет.

```bash
./max_object_size_probe.sh --bucket <bucket-name> --min <size> --max <size> --step <size> [options]
```

Required:

- `--bucket <name>`: bucket name, будет создан при отсутствии
- `--min <size>`: минимум, например `16kb`, `1mb`, `1gb`
- `--max <size>`: максимум
- `--step <size>`: шаг

Options:

- `--endpoint <url>`: default `http://192.168.10.81`
- `--cleanup`: удалить успешно загруженные объекты
- `--check`: после каждой успешной загрузки скачать объект и сравнить MD5 с исходным файлом; несовпадение считается ошибкой и останавливает цикл
- `-h`, `--help`: help

Size units: `kb`, `mb`, `gb`.

Examples:

```bash
./max_object_size_probe.sh --bucket test-bucket --min 1mb --max 100mb --step 5mb --cleanup
./max_object_size_probe.sh --bucket test-bucket --min 1mb --max 100mb --step 5mb --cleanup --check
```

Скрипт генерирует локальный файл для каждого размера, загружает его через `put-object`, удаляет локальный файл и печатает максимальный успешно загруженный размер. При `--check` объект скачивается во временный файл и сравнивается по MD5; временный файл удаляется независимо от результата проверки.

### `put_bunch_objects.sh`

Массовая последовательная загрузка объектов одинакового размера. Скрипт создает заданное количество локальных template-файлов и циклически использует их для загрузки нужного числа объектов с уникальными S3 keys.

```bash
./put_bunch_objects.sh --bucket <bucket-name> --size <size> --count <number> [options]
```

Required:

- `--bucket <name>`: bucket name, будет создан при отсутствии
- `--size <size>`: размер каждого объекта
- `--count <number>`, `-n <number>`: количество объектов

Options:

- `--unique <number>`: количество уникальных template-файлов, default `1`
- `--endpoint <url>`: default `http://192.168.10.81`
- `--cleanup`: удалить загруженные S3 objects после теста
- `--debug`: печатать AWS CLI команды и ответы
- `-h`, `--help`: help

Size units: `kb`, `mb`, `gb`.

Examples:

```bash
./put_bunch_objects.sh --bucket test-bucket --size 10mb --count 100
./put_bunch_objects.sh --bucket test-bucket --size 5mb -n 50 --unique 5 --cleanup
./put_bunch_objects.sh --bucket test-bucket --size 1gb --count 10 --unique 3 --debug
```

Если `--unique` больше `--count`, скрипт снижает `--unique` до `--count`. Локальные template-файлы удаляются через trap. S3 objects удаляются только при `--cleanup`.

## Ranged GetObject Testing

### `range_get_check.sh`

Проверяет поддержку опции `Range` в `GetObject`, включая объекты, загруженные через multipart upload.

```bash
./range_get_check.sh --bucket <bucket-name> --size <size> [options]
```

Required:

- `--bucket <name>`: bucket name, будет создан при отсутствии
- `--size <size>`: размер тестового объекта, например `100mb`, `1gb`

Options:

- `--gets <count>`: количество случайных ranged GetObject-запросов, default `100`
- `--multipart`: загрузить объект через multipart upload вместо обычного `put-object`
- `--range-max <size>`: максимальный размер случайного диапазона, например `64kb`, `1mb`, `16mb`, default `16mb`
- `--random-only`: пропустить детерминированные проверки границ и выполнить только случайные ranged GetObject-запросы (`--gets`)
- `--endpoint <url>`: default `http://192.168.10.81`
- `--cleanup`: удалить загруженный S3 object после теста
- `--debug`: печатать AWS CLI команды и ответы
- `-h`, `--help`: help

Size units: `--size` принимает `mb`, `gb`; `--range-max` принимает `kb`, `mb`, `gb` (`kb` — KiB, значение * 1024 байт).

Examples:

```bash
./range_get_check.sh --bucket test-bucket --size 100mb
./range_get_check.sh --bucket test-bucket --size 500mb --multipart --gets 200 --cleanup
./range_get_check.sh --bucket test-bucket --size 1gb --multipart --range-max 32mb --debug
./range_get_check.sh --bucket test-bucket --size 100mb --range-max 64kb --gets 300
./range_get_check.sh --bucket test-bucket --size 200mb --random-only --gets 500
```

Что делает скрипт:

1. Генерирует локальный файл случайных данных нужного размера.
2. Загружает его в S3 обычным `put-object`, либо через multipart upload при `--multipart`. Размер part для multipart подбирается автоматически (объект делится примерно на 8 частей, но не меньше 5MiB и не больше 10000 частей), part offsets и sizes всегда кратны 1MiB.
3. Выполняет набор детерминированных проверок границ: первый байт, короткий префикс от начала, последний байт, диапазон в конце объекта. При `--multipart` дополнительно добавляются: диапазон целиком внутри одной part, диапазон, заканчивающийся точно на границе part, диапазон, начинающийся точно на границе part, диапазон, пересекающий одну границу part, и (если parts не меньше 3) диапазон, пересекающий несколько границ part. При `--random-only` этот шаг полностью пропускается (в том числе для multipart-границ).
4. Выполняет `--gets` запросов со случайными диапазонами: случайное начало в пределах объекта, длина от 1 байта до `--range-max`, не выходящая за пределы объекта. Этот шаг выполняется всегда, в том числе при `--random-only`; при `--gets 0` случайных запросов не будет.
5. Для каждого диапазона проверяет: успешность запроса, метаданные ответа `GetObject` (JSON из stdout AWS CLI, разбирается через `jq`), совпадение размера скачанных данных с ожидаемым, побайтовое совпадение с соответствующим срезом исходного файла.

Проверка метаданных ответа (только top-level поля, без разбора HTTP статус-кода и без использования `--debug`-вывода AWS CLI):

- `ContentLength`: обязателен, должен равняться `end - start + 1`.
- `ContentRange`: обязателен, должен равняться `bytes <start>-<end>/<object-size-in-bytes>`.
- `AcceptRanges`: если присутствует, должен равняться `bytes`; если отсутствует, тест не падает, выводится `WARN`.

Каждый диапазон печатается как `PASS` или `FAIL` с меткой, `start`, `end` и ожидаемой/фактической длиной; при несовпадении содержимого выводится байт первого расхождения (`cmp`); при несовпадении метаданных выводятся ожидаемое и фактическое значения. Отсутствие `AcceptRanges` печатается как `WARN` и не считается ошибкой. Скрипт не останавливается на первой ошибке — все проверки выполняются, а итоговый exit code ненулевой, если хотя бы одна проверка провалилась.

Локальные temp-файлы (исходные данные, части, скачанные диапазоны) удаляются через trap. Незавершенные multipart uploads abort-ятся при выходе. Bucket не удаляется. S3 object удаляется только при `--cleanup`.

## Cleanup

### `cleanup_all.sh`

Удаляет все buckets и objects на указанном endpoint.

```bash
./cleanup_all.sh [endpoint-url]
```

Example:

```bash
./cleanup_all.sh http://192.168.10.81
```

Warning: это destructive-скрипт. Он удаляет все buckets на endpoint, включая обычные objects, versioned objects и delete markers. Перед выполнением есть 5-секундная пауза для отмены через `Ctrl+C`.

Используйте только на выделенном тестовом стенде.

## Size Formats

Поддержка единиц зависит от скрипта:

- `kb`: только `max_object_size_probe.sh` и `put_bunch_objects.sh`
- `mb`, `gb`: size probe, bulk upload, multipart-скрипты и `range_get_check.sh`
- `tb`: только `multipart_upload_check.sh` и `max_object_multipart_probe.sh`

Значения должны быть целыми и в нижнем регистре: `16kb`, `100mb`, `1gb`, `5tb`. Raw bytes без suffix скрипты не принимают.

## Resource and Cleanup Notes

- `base_check.sh` использует фиксированные bucket names. Не запускайте его против окружения, где такие buckets могут содержать чужие данные.
- `spec_methods_tester.sh` создает bucket с timestamp и временную директорию в `/tmp`; cleanup выполняется автоматически.
- `multipart_upload_check.sh`, `max_object_multipart_probe.sh` и `range_get_check.sh` abort-ят активные multipart uploads при выходе.
- `--cleanup` в probe/bulk скриптах и в `range_get_check.sh` удаляет только успешно загруженные S3 objects, но не bucket.
- `cleanup_all.sh` удаляет все buckets на endpoint и не различает тестовые и нетестовые данные.

## Troubleshooting

Connection errors:

- проверьте endpoint URL и доступность порта
- проверьте credentials AWS CLI
- убедитесь, что endpoint начинается с `http://` или `https://` для `spec_methods_tester.sh`

Authentication or permission errors:

- нужны права на `list-buckets`, `create-bucket`, `delete-bucket`, `put-object`, `get-object`, `delete-object`
- для расширенных тестов нужны права на versioning, tagging и multipart operations

Multipart failures:

- сначала проверьте `test_multipart.sh`, но помните, что bucket и endpoint в нем hard-coded
- part size должен соответствовать требованиям S3-compatible API
- проверьте лимит на количество parts, обычно 10 000
- для больших объектов убедитесь, что достаточно локального места в `/tmp`

Cleanup failures:

- versioned buckets могут требовать удаления всех versions и delete markers
- для полного сброса тестового стенда используйте `cleanup_all.sh`, но только если endpoint выделен под тесты

## Recommended Test Order

1. `check_connection.sh`
2. `base_check.sh`
3. `spec_methods_tester.sh -e <endpoint> -v -c`
4. `test_multipart.sh`, если его hard-coded endpoint/bucket подходят стенду
5. `multipart_upload_check.sh` на малом размере
6. `max_object_size_probe.sh` или `max_object_multipart_probe.sh` для поиска пределов
7. `put_bunch_objects.sh` для массовой загрузки и оценки поведения под нагрузкой
8. `range_get_check.sh` для проверки поддержки ranged GetObject, в том числе для multipart-объектов
9. `cleanup_all.sh` только для полной очистки выделенного тестового endpoint
