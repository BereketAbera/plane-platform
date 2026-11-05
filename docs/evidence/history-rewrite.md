# The history rewrite of 2026-11-05

At 13:53Z, before any of it reached GitHub, the local history after `0dde813` was rewritten with `git filter-branch`. It removed a plane-dev session cookie from two evidence files. [The scrub](README.md#the-scrub) says how the value got there. It fit no gitleaks rule, so a clean `gitleaks` run over the history could not have cleared it.

## What changed

In each commit that held `docs/evidence/runs/load-20261105T073241Z/k6.log` or `k6-summary.json`, those two files became their scrubbed versions. Nothing else was edited. Because a commit's id depends on its content and its parents, every commit from the one that added those files onward has a new id: 246 of the 344 commits in the range.

## What was checked

Read at 13:53Z, and again across every ref at 13:55Z:

| Check | Result |
|---|---|
| The tip before and after | `git diff 601f012 07feb13` is empty, so the two trees are identical |
| Author, committer, both dates and subject | The same across all 344 commits, line for line |
| A search of every blob only that history holds, for session values, CSRF tokens, bearer tokens, GitHub and Infisical tokens, JWTs and private keys | No finding in 2,011 blobs. The same search before the rewrite found the two blobs above and nothing else |
| `gitleaks git` over the history | Exit 0, which says nothing about the session value on its own |
| The search below | 0 |

The search for session values, which gitleaks does not do. It belongs beside `gitleaks` before the repository goes public:

```bash
git log -p --all | grep -cE '"session(_id|-id)?" *: *"[A-Za-z0-9_-]{16,}|session(-id|_id)?=[A-Za-z0-9_-]{16,}'
```

## The session itself

It still worked. Read at 13:55:43Z from this machine, `GET /api/users/me/` on `plane.dev.localhost` answered 200 with it. Signing it out answered 302, and the same request then answered 401. The value was not printed in any of this. It belonged to the generated smoke account on a host only this machine can reach.

## What it leaves

- GitHub never held the value. `origin/main` read `0dde813` until the push after this rewrite.
- The old commits stay as unreachable objects in this machine's own Git stores, here and in the bare repository, until Git expires them. No push sends them.
- `scripts/gitops-publish.sh` refuses a non-fast-forward on purpose, so that Argo CD never follows a rewrite with no record of it. This page is that record. The bare repository was moved once by hand, with `git push --force`, and `.local/publishes.log` was put through the same map, so `make rollback` still finds each publish.
- Raw evidence was not edited. A commit id inside a file under `runs/`, or in a commit message, is the id at the time, so read it through the map below. Prose under `docs/`, `README.md` and `PASS2_HANDOFF.md` was moved to the new ids.

## Map of old ids to new ids

| Old | New |
|---|---|
| `7d5ff62da5` | `94a54e23b5` |
| `5abd9a9cab` | `0e6db5c408` |
| `ff00f5080d` | `1889487282` |
| `431d306d64` | `360dc54a2f` |
| `404479f997` | `8afdd3e917` |
| `f64e375c92` | `c8d6ff4a62` |
| `40de59d504` | `a483298510` |
| `75c4b77f72` | `1bf53a45c3` |
| `2b8fd1f647` | `fa0632ac8a` |
| `e3cc88025f` | `3149a4e1a5` |
| `9bdc5f470c` | `eeaa78206f` |
| `5aad299d3b` | `3db28e8c13` |
| `5d7bf14d51` | `4d074153c2` |
| `88372d9bc9` | `32e0fab706` |
| `68f882821a` | `94e1811bb4` |
| `4fef299b9f` | `dc2643d55b` |
| `6d6e9b1fc2` | `635322100d` |
| `eabbe13c19` | `6422738581` |
| `1b36cad17c` | `f4ecff1617` |
| `7c91f50112` | `561720c4be` |
| `12e24b9f3a` | `79223c8cc2` |
| `6d2f6a0fdd` | `eb16aa3605` |
| `55147f4b4e` | `c84c39ae1c` |
| `18130d42ee` | `28fc2167da` |
| `7ecd81703a` | `e71bbd9478` |
| `1489a46d0e` | `13d7930a2f` |
| `967a1c2d3d` | `bad11bc73f` |
| `e37b454152` | `5705db4e97` |
| `c1630a0d51` | `90701b9b7d` |
| `8a3d9586cb` | `6a8b0c879a` |
| `95b68215b3` | `ba91b1a2aa` |
| `0d3484f13e` | `2df740ef4a` |
| `349ec81df6` | `affcb0364a` |
| `548835dca4` | `397bf78794` |
| `200801b025` | `e235e676a9` |
| `743221015b` | `07325683c2` |
| `957a1802c9` | `b9af0ee18a` |
| `a3ed4088ab` | `d7f0713885` |
| `5b905c5e8a` | `5a06915c63` |
| `1255c68f2d` | `051a4a861f` |
| `808c8f65a1` | `9fca35432b` |
| `2562470ee0` | `f2e90dcac7` |
| `d7bf477b91` | `195bb7f2ec` |
| `c694335342` | `93f95c190b` |
| `f8dce67292` | `3e5196475e` |
| `ea81d47b10` | `b496d03e15` |
| `4a38408899` | `f48e243534` |
| `e500c48fcd` | `7401dc7570` |
| `ec0a00be03` | `142804e1a9` |
| `a157767fa3` | `befd5fb402` |
| `02ed4a339e` | `dac534064f` |
| `f54a3300cf` | `5e22bfdc99` |
| `ae0ed10b0b` | `56372b80f3` |
| `6f18ef4207` | `a56fb0d971` |
| `46a0e06387` | `e5d65fd230` |
| `488ae43e48` | `cc64b25f5d` |
| `9288a6cc4f` | `6fe6017c21` |
| `413aa18a29` | `79ac1ea1d6` |
| `29d01465fc` | `d01a1cb43a` |
| `0f046e25e7` | `cd2613fc36` |
| `43db8e6c94` | `365a5b8b6e` |
| `4ccf316de9` | `48f6d43c3f` |
| `4eab989825` | `0a6d7fe432` |
| `e23e17e417` | `cc6c8f546a` |
| `bf41d786e8` | `3c52703892` |
| `fa6339b20c` | `dfa92f51d2` |
| `5c87ab6e09` | `da285f5bff` |
| `a4e662a9b1` | `23f17aee99` |
| `f96ed8058a` | `ab4eac95eb` |
| `bafae854b2` | `5b7904c002` |
| `a45700945d` | `9e8dcee460` |
| `ed2f2597ee` | `20c3e978c2` |
| `94a77e014b` | `6fc82d49ec` |
| `a7b42b0c7c` | `b71769049c` |
| `bcb495c8e5` | `5b50b00f4f` |
| `b4279f51ce` | `e28ba569ed` |
| `cc32d47487` | `fe40bef99b` |
| `b7be5960f9` | `fb07076a59` |
| `99e9807269` | `b473021657` |
| `ea67fc84fb` | `79319cb0f6` |
| `00126ea846` | `af8b26ea1e` |
| `15d24fd42c` | `3e87cc0876` |
| `ddef6cde26` | `ed85a5d359` |
| `85bdeb3392` | `6935b77400` |
| `3c652f43bc` | `febfebf3e5` |
| `03c928eec1` | `c5466ef07b` |
| `d229eb28ad` | `2526b1e934` |
| `e0eec2c485` | `2849593947` |
| `6260fd0209` | `9fdc6a2171` |
| `174d43a34a` | `46989b7727` |
| `8ce9eff47a` | `df75d590ec` |
| `1f7d7880f7` | `adb541f0ca` |
| `0ff82dc1b5` | `4599d73a79` |
| `f71bba9c06` | `b236842aa8` |
| `d1a2f127ec` | `ead555c7ae` |
| `eed04aa7f6` | `8d6303ac11` |
| `6e22ea5f1b` | `ba682aaf9f` |
| `5cd3421f03` | `e6ddddfcee` |
| `0ddb226b4c` | `e46ffc2470` |
| `ead789e555` | `0d31f3a902` |
| `1b825d840c` | `890b82ef55` |
| `c55d325212` | `1a63fa2b76` |
| `122d43b6c5` | `bbff5ae25c` |
| `27b34ff420` | `1e36683b86` |
| `11b92d4857` | `5df20faad9` |
| `5d4cc53487` | `f5457690bf` |
| `97d7900a0b` | `a9ed3c0200` |
| `030fac9ea3` | `15f81f6f1f` |
| `cf78181aa1` | `72d37a5458` |
| `eaa1100a19` | `a642d12def` |
| `723f3848a6` | `b98ec32cfd` |
| `bb1d481803` | `d6152c6635` |
| `e6c2b73d05` | `d1d271112c` |
| `4ef2b71229` | `9885f10218` |
| `07700a64e7` | `fca4522374` |
| `bfa91e9d54` | `bf7800caa5` |
| `2b6a0489ac` | `0f5e09a6b7` |
| `4c913e1a6a` | `8c9fd3fbf1` |
| `bfe4f97465` | `7b07305a1e` |
| `ed6056fca1` | `c379545af6` |
| `0236279fb3` | `d898060f1a` |
| `96ddde23aa` | `fd50ddaee4` |
| `d478cad263` | `43a5ab43ee` |
| `ec6aa89ab4` | `846f9e0b6f` |
| `613c2a0ad1` | `d5fb771177` |
| `2f42ddb7f9` | `63105af9ba` |
| `699ab8a5dd` | `233b21f451` |
| `ed089b4650` | `fba8b157ca` |
| `6cd74a200f` | `a7759517b5` |
| `56c3bf62f8` | `1965a1b48e` |
| `e1c33ac93f` | `5dd4e2f009` |
| `c3dd02ec38` | `b0a0e830c5` |
| `adb0e83f90` | `fb43064af1` |
| `af81274d23` | `266978bd1f` |
| `11aa89986a` | `98c4b36ffb` |
| `0e1c311c2f` | `48a8227c03` |
| `77437abdd3` | `e56c507a0a` |
| `74d5f4b552` | `8cdebfc36e` |
| `2e566c9ba4` | `47ec2f92b4` |
| `75249819d9` | `05a951609e` |
| `c1d4dc0d66` | `0ed9efe30c` |
| `80d38c17f4` | `6f4077b006` |
| `a361a6f194` | `4b41732786` |
| `b51719d93d` | `0784dd12e8` |
| `e579c9c5af` | `66afe3ef3f` |
| `bb44f8e7ae` | `de43fb8cad` |
| `14d2a17685` | `52c47446a1` |
| `18af97ac12` | `e602dad7cc` |
| `52380f46fc` | `ec96c19879` |
| `f4aa2db510` | `e2bc79c477` |
| `f457f7e431` | `a7e08f506a` |
| `44b7a03812` | `88ecfd3719` |
| `404cc1b556` | `e5b713a837` |
| `2008fac1c1` | `0443ea4409` |
| `10c78d44ce` | `18bf9424d8` |
| `12ec262936` | `af42052c2d` |
| `323669df73` | `5e5043868f` |
| `a03e373267` | `7f2f7870df` |
| `fc3f8d682c` | `92b28b9146` |
| `e0e2c59cab` | `ba843926ca` |
| `faa9dbfa61` | `7a620d38e0` |
| `98cfd9309d` | `7d64061b50` |
| `0d22876af8` | `3980c30d38` |
| `ad7195f8be` | `4e1dc00231` |
| `e981aafb1f` | `27bd10987f` |
| `f89b539850` | `809de84067` |
| `e1d92b2abe` | `a0c878f04a` |
| `788d1e4b33` | `d0ddc82b68` |
| `47803eb7e4` | `31b1c40c30` |
| `fe9520ec3b` | `c2fa4944b3` |
| `8cd6a7befe` | `8e7345f6b4` |
| `8d6abcfe33` | `e16173b371` |
| `6af1778162` | `c17f36669c` |
| `829da86d5c` | `9bfb8a4475` |
| `bec0507102` | `39512c380e` |
| `087a3197da` | `697846152b` |
| `374620d454` | `3d76ce9dc8` |
| `e2be142837` | `a585213350` |
| `b30bcdd293` | `fde62fde37` |
| `5ac25d80ad` | `413a49ccb8` |
| `406a2ee2db` | `04f83494bc` |
| `a1836ee071` | `fda03e7146` |
| `6f5a42653a` | `b4f6cc93b6` |
| `36d3011251` | `1374c1e841` |
| `f9abc2a74f` | `06b8be7a55` |
| `5e67edbf5a` | `85bb2f343e` |
| `efcfd54144` | `3dfe55274f` |
| `408c05d490` | `bc90e0dfcf` |
| `53aa28447e` | `6b70cd7e12` |
| `fa0ff30833` | `8ba5a261d1` |
| `4612200640` | `0110944a1b` |
| `27149e97a9` | `f6f171d5a2` |
| `fbb72672bc` | `4c3b3c00d0` |
| `a4fd0f864c` | `136de2fef2` |
| `8d3c8090d5` | `bf11892a88` |
| `4c48c154b0` | `e7734f215b` |
| `b012933fce` | `7548ecb513` |
| `2ddb452272` | `07f01447f5` |
| `b448f3a5a6` | `637515f76f` |
| `d4d927eb6e` | `caa679b7bf` |
| `d6d8433591` | `3c85221ddb` |
| `3b17f90741` | `57efc0b9f7` |
| `4132feefdd` | `d12da0f544` |
| `98dc05e74b` | `03cf7a0a8e` |
| `56bffbc386` | `fb28a4df77` |
| `c37f07e3c5` | `ac4d1b3851` |
| `7b1859e7b0` | `d7b231490d` |
| `37561cf444` | `7aa0290a78` |
| `316e0a4de2` | `6f90c5a70d` |
| `9aa7a13b95` | `d758539280` |
| `b1436378aa` | `f9335c3aa6` |
| `174138a407` | `4e9fa166b3` |
| `019130ae6b` | `c96b15e63d` |
| `07bde9aa55` | `0c981739c3` |
| `c30af692f9` | `97c7c85186` |
| `fea379b8b7` | `b5890de1cc` |
| `c284bd31c0` | `d716cf7314` |
| `0c5a35cce3` | `81a10c5ce2` |
| `c55ed5913f` | `31e5f4b1f6` |
| `f321feff94` | `1e5bbfeb5d` |
| `4660b87d93` | `2fc7e729fc` |
| `75e7a72301` | `30831b462b` |
| `e0f09135d8` | `5cbf8d5b03` |
| `77d1f4c7c3` | `5b3557b038` |
| `1f14c402d2` | `77dc9c25e6` |
| `f2a83afc97` | `da905834b5` |
| `ba67341502` | `2701ebca31` |
| `cdfaefc597` | `02c48597f3` |
| `aeadd9609e` | `6e20e81ef0` |
| `2f9d261dda` | `6c9d4a8934` |
| `a3dd813ac3` | `b58559881a` |
| `0910d17292` | `5054573a9e` |
| `500d071ffe` | `c8a12a8183` |
| `7ebab899aa` | `a08a1fab6f` |
| `1a0bb7887d` | `ce5d578787` |
| `ba2c4642b1` | `c681f4b651` |
| `187340793a` | `d8b381bba2` |
| `d2d0ab7474` | `90d74ff5f1` |
| `fba50fd29e` | `c964a3225e` |
| `6fdfb51915` | `90ef49566c` |
| `178dc171c1` | `3d44384ec8` |
| `ac92c3b695` | `d336d4b1d8` |
| `0e6b08aa80` | `a5bdf1bd93` |
| `a7fd11407b` | `91afdb1bc6` |
| `b0272d4ed5` | `69b881c2ad` |
| `601f012241` | `07feb13839` |
