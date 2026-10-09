# synolun

Synology DSMのiSCSI LUNとiSCSIターゲットを、コマンドラインから一覧・削除するシェルスクリプトです。

[synology-csi](https://github.com/SynologyOpenSource/synology-csi)と同じDSM Web API（`SYNO.Core.ISCSI.LUN` / `SYNO.Core.ISCSI.Target`）を`curl`で直接呼び出します。主な用途は、Kubernetesで`reclaimPolicy: Retain`のPVを削除した後に、NAS上に残ったLUNやターゲットを掃除することです。

## 必要なもの

- bash
- curl
- python3（JSONの処理に使用。標準ライブラリだけで動きます）
- iSCSIの管理権限を持つDSMアカウント

## セットアップ

```bash
export DSM_HOST=192.168.10.50   # 必須: NASのアドレス
./synolun.sh login <account>    # パスワードを聞かれます
```

| 環境変数 | 既定値 | 説明 |
|---|---|---|
| `DSM_HOST` | （必須） | NASのホスト名またはIPアドレス |
| `DSM_PORT` | `5000` | DSMのポート |
| `DSM_SCHEME` | `http` | `https`を使う場合は`DSM_PORT=5001`と組み合わせます |
| `DSM_INSECURE` | `0` | `1`にするとTLS証明書を検証しません（自己署名証明書向け） |

ログインすると、セッション（ベースURLとsid）が`~/.config/synolun/session`（パーミッション600）に保存されます。sidが期限切れになるか`logout`するまでは、再ログインは不要です。

> **注意:** `login`はパスワードを`read -s`で読み込むので、TTYが必要です。TTYのない環境（CIや、TTYを割り当てないツール経由の実行など）では、何も表示せずに失敗します。必ず通常のターミナルで実行してください。

## コマンド

| コマンド | 説明 |
|---|---|
| `login <account>` | ログインし、セッションを保存する |
| `logout` | セッションを無効化し、保存ファイルを削除する |
| `list` | LUNを一覧表示する（UUID、名前、サイズ、マップ状態、状態） |
| `get <uuid>` | LUN 1つの詳細をJSONで表示する（マップ先のターゲットも含む） |
| `delete [-y] <uuid>...` | LUNを削除する |
| `targets [--orphans]` | iSCSIターゲットを一覧表示する。`--orphans`を付けると、LUNもセッションもないものだけを表示する |
| `target-delete [-y] <target_id>...` | iSCSIターゲットを削除する |
| `help` | ヘルプを表示する |

`delete`と`target-delete`は、`-y`/`--yes`を付けない場合、実行前に`yes`の入力を求めます。

`target-delete`は、指定したIDに次のいずれかが含まれていると、**1つも削除せずに終了**します。

- LUNがマップされているターゲット
- イニシエータが接続中のターゲット
- 存在しないID

`delete`には、このような安全チェックはありません。LUNが使用中かどうかは、事前に`list`の`MAPPED`列や`get`で確認してください。

## 使用例

```console
$ ./synolun.sh list
UUID                                   NAME                          SIZE(GiB) MAPPED     STATUS
c81088d4-178a-40f4-8013-4ffaa07d0682   k8s-csi-pvc-e1afd34d-...           10.0 True       normal

$ ./synolun.sh targets --orphans
  ID NAME                                                  LUNS SESSIONS STATUS
  58 k8s-csi-pvc-92d5d831-ef5f-4765-8262-07873420d9f0         0        0 online
```

## Kubernetesで残ったボリュームを掃除する手順

synology-csiでは、PV・LUN・ターゲットが次のように対応しています。

| Kubernetes | DSM |
|---|---|
| PV名 `pvc-<uuid>` | LUN名・ターゲット名 `k8s-csi-pvc-<uuid>` |
| PVの`spec.csi.volumeHandle` | LUNのUUID |

`Retain`のPVを`kubectl delete pv`しても、NAS上のLUNとターゲットは残ります。また、`delete`はLUNだけを削除し、ターゲットは空のまま残ります。そのため、次の順番で掃除します。

1. **ReleasedになっているPVと、そのLUNのUUIDを確認する**

   ```bash
   kubectl get pv -o json | jq -r '.items[] | select(.status.phase=="Released")
     | [.metadata.name, .spec.claimRef.namespace + "/" + .spec.claimRef.name, .spec.csi.volumeHandle] | @tsv'
   ```

2. **PVを削除する。** 事前に`kubectl get volumeattachment`で、どのノードにもアタッチされていないことを確認してください。

   ```bash
   kubectl delete pv <pv-name>...
   ```

3. **LUNを削除する。** `list`で、対象のUUIDが存在し、名前が`k8s-csi-<PV名>`と一致することを確認してから削除します。

   ```bash
   ./synolun.sh delete <uuid>...
   ```

4. **空になったターゲットを削除する**

   ```bash
   ./synolun.sh targets --orphans
   ./synolun.sh target-delete <target_id>...
   ```

5. **整合性を確認する。** `list`のLUN数と`targets`のターゲット数が、BoundのPV数と一致していれば完了です。

   PVのないLUNが残っていないかは、次のコマンドで確認できます（何も表示されなければOK）。

   ```bash
   kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' > /tmp/live.txt
   ./synolun.sh list | tail -n +2 | grep -vFf /tmp/live.txt
   ```

## DSMのエラーコード

| コード | 意味 | 対処 |
|---|---|---|
| 106 | セッションのタイムアウト | `login`し直す |
| 119 | sidが無効 | `login`し直す |
