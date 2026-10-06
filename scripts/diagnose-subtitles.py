#!/usr/bin/env python3
"""诊断某一集的字幕：列出 Emby / Jellyfin 返回的字幕流，并实测服务器提取字幕的耗时。

用途：对比 Vela（iOS）与 JellyCine（Android）字幕行为时，先确认服务器侧数据——字幕是内嵌还是外挂、
codec、是否带默认标记、服务器是否判定为文本字幕。这些字段决定 iOS 走哪条路径：
  - 内嵌文本字幕 + MKV：KSPlayer 直接从视频流读取（PlayerSession.selectSubtitle）
  - 外挂字幕：请求服务器 /Videos/{id}/{source}/Subtitles/{index}/0/Stream.vtt 转 WebVTT
  - 图形字幕（PGS 等）：只能服务器烧录
另外起播时只有「记住的语言 > 首选字幕语言 > 服务器 DefaultSubtitleStreamIndex」命中才会自动开启字幕。

密码只在本进程内存中使用，不写入任何文件；只用 Python 标准库。
用法：
  python3 scripts/diagnose-subtitles.py --server http://host:8096 --user NAME --series 兰香如故 --season 1 --episode 13
"""
import argparse
import getpass
import json
import sys
import time
import urllib.parse
import urllib.request
import uuid

CLIENT = 'MediaBrowser Client="VelaDiagnose", Device="mac", DeviceId="{}", Version="1.0"'.format(uuid.uuid4().hex)


def request(base, path, token=None, method="GET", body=None, query=None, timeout=60, raw=False):
    url = base.rstrip("/") + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    auth = CLIENT + (', Token="{}"'.format(token) if token else "")
    headers = {"X-Emby-Authorization": auth, "Authorization": auth, "Accept": "application/json"}
    if token:
        headers["X-Emby-Token"] = token
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = resp.read()
    return payload if raw else json.loads(payload or b"null")


def detect_base(server):
    """Emby 的 API 在 /emby 下（也兼容无前缀），Jellyfin 无前缀；按 System/Info/Public 探测。"""
    for base in (server.rstrip("/") + "/emby", server.rstrip("/")):
        try:
            info = request(base, "/System/Info/Public", timeout=15)
            return base, info.get("ProductName") or info.get("ServerName")
        except Exception:
            continue
    sys.exit("无法访问服务器：{}".format(server))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--server", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--series", required=True, help="剧名关键词")
    parser.add_argument("--season", type=int, required=True)
    parser.add_argument("--episode", type=int, required=True)
    parser.add_argument("--no-fetch", action="store_true", help="不实测下载字幕（服务器提取内嵌字幕可能要读完整个文件）")
    args = parser.parse_args()

    base, product = detect_base(args.server)
    print("服务器：{}（API {}）".format(product, base))
    password = getpass.getpass("密码（不回显）：")
    auth = request(base, "/Users/AuthenticateByName", method="POST", body={"Username": args.user, "Pw": password})
    del password
    token, user_id = auth["AccessToken"], auth["User"]["Id"]

    try:
        series = request(base, "/Items", token, query={
            "UserId": user_id, "Recursive": "true", "IncludeItemTypes": "Series", "SearchTerm": args.series, "Limit": 5})
        if not series.get("Items"):
            sys.exit("找不到剧集：{}".format(args.series))
        series_id = series["Items"][0]["Id"]
        episodes = request(base, "/Shows/{}/Episodes".format(series_id), token, query={"UserId": user_id, "Season": args.season})
        episode = next((e for e in episodes.get("Items", []) if e.get("IndexNumber") == args.episode
                        and e.get("ParentIndexNumber", args.season) == args.season), None)
        if not episode:
            sys.exit("找不到 S{}E{}".format(args.season, args.episode))
        item_id = episode["Id"]
        print("条目：{} S{}E{} {}（Id {}）".format(series["Items"][0]["Name"], args.season, args.episode, episode.get("Name"), item_id))

        # 不带 DeviceProfile 的 PlaybackInfo：只看服务器记录的原始流信息。
        info = request(base, "/Items/{}/PlaybackInfo".format(item_id), token, method="POST",
                       query={"UserId": user_id}, body={})
        for source in info.get("MediaSources", []):
            print("\n版本 {}：container={} path={}".format(source.get("Id"), source.get("Container"), source.get("Path")))
            print("  DefaultSubtitleStreamIndex = {}".format(source.get("DefaultSubtitleStreamIndex")))
            subs = [s for s in source.get("MediaStreams", []) if s.get("Type") == "Subtitle"]
            if not subs:
                print("  ⚠️ 服务器没有记录任何字幕流（视频可能是硬字幕，或需要在服务器上刷新元数据 / 放入外挂字幕）")
            for s in subs:
                print("  #{Index} codec={Codec} lang={Language} title={DisplayTitle} external={IsExternal} "
                      "default={IsDefault} forced={IsForced} text={IsTextSubtitleStream} "
                      "delivery={DeliveryMethod}".format(**{k: s.get(k) for k in (
                          "Index", "Codec", "Language", "DisplayTitle", "IsExternal", "IsDefault", "IsForced",
                          "IsTextSubtitleStream", "DeliveryMethod")}))
                if s.get("Path"):
                    print("      path={}".format(s["Path"]))
                if args.no_fetch:
                    continue
                fmt = "srt" if (s.get("Codec") or "").lower() in ("subrip", "srt") else "vtt"
                started = time.time()
                try:
                    data = request(base, "/Videos/{}/{}/Subtitles/{}/0/Stream.{}".format(item_id, source["Id"], s["Index"], fmt),
                                   token, timeout=300, raw=True)
                    text = data.decode("utf-8", "replace")
                    print("      Stream.{} → {} 字节，{} 个时间行，耗时 {:.1f}s".format(
                        fmt, len(data), text.count("-->"), time.time() - started))
                    first = next((line for line in text.splitlines() if "-->" in line), None)
                    print("      首条时间：{}".format(first))
                except Exception as error:
                    print("      Stream.{} 失败（{:.1f}s）：{}".format(fmt, time.time() - started, error))
    finally:
        # 注销本次会话，不在服务器上留下诊断设备的令牌。
        try:
            request(base, "/Sessions/Logout", token, method="POST", raw=True)
        except Exception:
            pass


if __name__ == "__main__":
    main()
