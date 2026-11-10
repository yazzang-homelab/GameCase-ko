import json
import plistlib
import re
import requests
import os
from datetime import datetime

def prepare_description(text):
    text = re.sub('<[^<]+?>', '', text) # Remove HTML tags
    text = re.sub(r'#{1,6}\s?', '', text) # Remove markdown header tags
    text = re.sub(r'\*{2}', '', text) # Remove all occurrences of two consecutive asterisks
    text = re.sub(r'(?<=\r|\n)-', '•', text) # Only replace - with • if it is preceded by \r or \n
    text = re.sub(r'`', '"', text) # Replace ` with "
    text = re.sub(r'\r\n\r\n', '\r \n', text) # Replace \r\n\r\n with \r \n (avoid incorrect display of the description regarding paragraphs)
    return text

def load_source_data(repo_url, filename):
    # Base copy of a source JSON: it lives as an asset on the latest stable
    # release (fall back to the nightly release, then to the repo seed file).
    # This replaces the old fixed "1.0" hosting release, which has been removed.
    try:
        response = requests.get(f"https://api.github.com/repos/{repo_url}/releases",
                                headers={"Accept": "application/vnd.github+json"})
        response.raise_for_status()
        releases = response.json()
    except requests.RequestException:
        releases = []

    def rank(release):
        if release.get("tag_name") == "nightly":
            return 1
        if release.get("draft") or release.get("prerelease"):
            return 2
        return 0

    for release in sorted(releases, key=rank):
        for asset in release.get("assets", []):
            if asset["name"] == filename:
                r = requests.get(asset["browser_download_url"])
                r.raise_for_status()
                return r.json()

    with open(f"./.github/{filename}", "r") as file:
        return json.load(file)

def fetch_latest_release(repo_url, is_nightly: bool):
    api_url = f"https://api.github.com/repos/{repo_url}/releases"
    headers = {
        "Accept": "application/vnd.github+json",
    }
    try:
        response = requests.get(api_url, headers=headers)
        response.raise_for_status()
        releases = response.json()
        latest_release = next((
            release for release in releases
            if (release["tag_name"] == "nightly") == is_nightly
        ), None)
        return [latest_release] if latest_release else []
    except requests.RequestException as e:
        print(f"Error fetching releases: {e}")
        raise

def get_file_size(url):
    try:
        response = requests.head(url)
        response.raise_for_status()
        return int(response.headers.get('Content-Length', 0))
    except requests.RequestException as e:
        print(f"Error getting file size: {e}")
        return 194586

def strip_empty_channels(data):
    # SideStore's decoder rejects the whole source when any release channel
    # carries an empty releases list ("At least one version is required in
    # key: releases"). A seed-fallback base (.github/*.json) ships empty
    # channel skeletons and the per-track fills only touch one track per
    # run, so never write an empty channel out.
    for app in data.get("apps", []):
        channels = app.get("releaseChannels")
        if channels:
            app["releaseChannels"] = [c for c in channels if c.get("releases")]


def update_json_file_release(repo_url, json_file, latest_release, source_name="apps.json"):
    if isinstance(latest_release, list) and latest_release:
        latest_release = latest_release[0]
    else:
        print("Error getting latest release")
        return

    data = load_source_data(repo_url, source_name)

    app = data["apps"][0]

    with open("LiveContainer/Info.plist", 'rb') as infile:
        info_plist = plistlib.load(infile)
    full_version = info_plist["CFBundleVersion"]

    tag = latest_release["tag_name"]
    version = re.search(r"(\d+\.\d+\.\d+)", full_version).group(1)
    version_date = latest_release["published_at"]
    date_obj = datetime.strptime(version_date, "%Y-%m-%dT%H:%M:%SZ")

    description = latest_release["body"]
    description = prepare_description(description)

    assets = latest_release.get("assets", [])
    download_url = None
    size = None
    for asset in assets:
        if asset["name"] == f"GameCase.ipa":
            download_url = asset["browser_download_url"]
            size = asset["size"]
            break

    if download_url is None or size is None:
        print("Error: IPA file not found in release assets.")
        return

    version_entry = {
        "version": version,
        "date": version_date,
        "localizedDescription": description,
        "downloadURL": download_url,
        "size": size
    }

    duplicate_entries = [item for item in app["versions"] if item["version"] == version]
    if duplicate_entries:
        app["versions"].remove(duplicate_entries[0])

    app["versions"].insert(0, version_entry)

    app.update({
        "version": version,
        "versionDate": version_date,
        "versionDescription": description,
        "downloadURL": download_url,
        "size": size
    })

    if "news" not in data:
        data["news"] = []

    news_identifier = f"release-{full_version}"
    date_string = date_obj.strftime("%d/%m/%y")
    news_entry = {
        "appID": "com.tiaoge.gamecase",
        "caption": f"Update of GameCase just got released!",
        "date": latest_release["published_at"],
        "identifier": news_identifier,
        "imageURL": "https://raw.githubusercontent.com/Tiaoge-tou/GameCase/main/screenshots/release-gc-v1.png",
        "notify": True,
        "tintColor": "#0784FC",
        "title": f"{full_version} - GameCase  {date_string}",
        "url": f"https://github.com/Tiaoge-tou/GameCase/releases/tag/{tag}"
    }

    news_entry_exists = any(item["identifier"] == news_identifier for item in data["news"])
    if not news_entry_exists:
        data["news"].append(news_entry)

    strip_empty_channels(data)

    try:
        with open(json_file, "w") as file:
            json.dump(data, file, indent=2)
        print("JSON file updated successfully.")
    except IOError as e:
        print(f"Error writing to JSON file: {e}")
        raise

def update_json_file_nightly(json_file, nightly_release):
    if isinstance(nightly_release, list) and nightly_release:
        nightly_release = next((item for item in nightly_release if item["tag_name"] == "nightly"), None)
    else:
        print("Error getting nightly release")
        return

    try:
        with open(json_file, "r") as file:
            data = json.load(file)
    except json.JSONDecodeError as e:
        print(f"Error reading JSON file: {e}")
        data = {"apps": []}
        raise

    app = data["apps"][0]

    with open("LiveContainer/Info.plist", 'rb') as infile:
        info_plist = plistlib.load(infile)
    full_version = info_plist["CFBundleVersion"]
    tag = nightly_release["tag_name"]
    version = re.search(r"(\d+\.\d+\.\d+)", full_version).group(1)
    version_date = nightly_release["published_at"]
    date_obj = datetime.strptime(version_date, "%Y-%m-%dT%H:%M:%SZ")

    nightly_link = os.environ.get("NIGHTLY_LINK", "")
    commit_sha = os.environ.get("commit_sha", "")[:7]
    commit_msg = os.environ.get("commit_msg", "").strip()

    description = f"""\
Nightly build from [{commit_sha}](https://github.com/Tiaoge-tou/GameCase/commit/{commit_sha}):\
 {commit_msg}

This is a nightly release [created automatically with GitHub Actions workflow]({nightly_link}).
"""
    description = prepare_description(description)

    assets = nightly_release.get("assets", [])
    download_url = None
    size = None
    for asset in assets:
        if asset["name"] == f"GameCase.ipa":
            download_url = asset["browser_download_url"]
            size = asset["size"]
            break

    if download_url is None or size is None:
        print("Error: IPA file not found in release assets.")
        return

    version_entry = {
        "version": version,
        "date": version_date,
        "localizedDescription": description,
        "downloadURL": download_url,
        "size": size,
        "commit": commit_sha,
        "headline": commit_msg
    }

    app["versions"].clear()
    app["versions"].append(version_entry)

    app.update({
        "version": version,
        "versionDate": version_date,
        "versionDescription": description,
        "downloadURL": download_url,
        "size": size,
        "commit": commit_sha,
        "headline": commit_msg
    })

    data["news"] = []

    strip_empty_channels(data)

    try:
        with open(json_file, "w") as file:
            json.dump(data, file, indent=2)
        print("JSON file updated successfully.")
    except IOError as e:
        print(f"Error writing to JSON file: {e}")
        raise

def update_json_file_release_ss_lc(repo_url, json_file, latest_release, is_nightly: bool):
    if isinstance(latest_release, list) and latest_release:
        latest_release = latest_release[0]
    else:
        print("Error getting latest release")
        return

    data = load_source_data(repo_url, "apps_ss_lc.json")

    app = data["apps"][0]

    with open("LiveContainer/Info.plist", 'rb') as infile:
        info_plist = plistlib.load(infile)
    full_version = info_plist["CFBundleVersion"]

    tag = latest_release["tag_name"]
    version = re.search(r"(\d+\.\d+\.\d+)", full_version).group(1)
    version_date = latest_release["published_at"]
    date_obj = datetime.strptime(version_date, "%Y-%m-%dT%H:%M:%SZ")

    commit_sha = os.environ.get("commit_sha", "")[:7]
    commit_msg = os.environ.get("commit_msg", "").strip()

    description = f"""\
Nightly build from [{commit_sha}](https://github.com/Tiaoge-tou/GameCase/commit/{commit_sha}):\
 {commit_msg}
    """
    assets = latest_release.get("assets", [])
    download_url = None
    size = None
    for asset in assets:
        if asset["name"] == f"GameCase+SideStore.ipa":
            download_url = asset["browser_download_url"]
            size = asset["size"]
            break

    if download_url is None or size is None:
        print("Error: IPA file not found in release assets.")
        return

    version_entry = {
        "version": version,
        "date": version_date,
        "localizedDescription": description,
        "downloadURL": download_url,
        "size": size
    }

    if not is_nightly:
        duplicate_entries = [item for item in app["versions"] if item["version"] == version]
        if duplicate_entries:
            app["versions"].remove(duplicate_entries[0])

        app["versions"].insert(0, version_entry)

        app.update({
            "version": version,
            "versionDate": version_date,
            "versionDescription": description,
            "downloadURL": download_url,
            "size": size
        })
        channels = app['releaseChannels']
        for channel in channels:
            if channel['track'] != 'stable':
                continue
            channel['releases'] = app["versions"]


        if "news" not in data:
            data["news"] = []

        news_identifier = f"release-{full_version}"
        date_string = date_obj.strftime("%d/%m/%y")
        news_entry = {
            "appID": "com.tiaoge.gamecase",
            "caption": f"Update of GameCase just got released!",
            "date": latest_release["published_at"],
            "identifier": news_identifier,
            "imageURL": "https://raw.githubusercontent.com/Tiaoge-tou/GameCase/main/screenshots/release-gc-v1.png",
            "notify": True,
            "tintColor": "#0784FC",
            "title": f"{full_version} - GameCase  {date_string}",
            "url": f"https://github.com/Tiaoge-tou/GameCase/releases/tag/{tag}"
        }

        news_entry_exists = any(item["identifier"] == news_identifier for item in data["news"])
        if not news_entry_exists:
            data["news"].append(news_entry)
    else:
        channels = app['releaseChannels']
        for channel in channels:
            if channel['track'] != 'nightly':
                continue
            channel['releases'] = [version_entry]
    strip_empty_channels(data)

    try:
        with open(json_file, "w") as file:
            json.dump(data, file, indent=2)
        print("JSON file updated successfully.")
    except IOError as e:
        print(f"Error writing to JSON file: {e}")
        raise


def main():
    repo_url = "Tiaoge-tou/GameCase"
    is_nightly = "NIGHTLY_LINK" in os.environ

    try:
        fetched_data_latest = fetch_latest_release(repo_url, is_nightly)
        if is_nightly:
            json_file = "./.github/apps_nightly.json"
            update_json_file_nightly(json_file, fetched_data_latest)
            update_json_file_release_ss_lc(repo_url, "./.github/apps_ss_lc.json", fetched_data_latest, True)
        else:
            json_file = "./.github/apps.json"
            update_json_file_release(repo_url, json_file, fetched_data_latest)
            update_json_file_release(repo_url, "./.github/apps_lc.json", fetched_data_latest, source_name="apps_lc.json")
            update_json_file_release_ss_lc(repo_url, "./.github/apps_ss_lc.json", fetched_data_latest, False)
    except Exception as e:
        print(f"An error occurred: {e}")
        raise

if __name__ == "__main__":
    main()
