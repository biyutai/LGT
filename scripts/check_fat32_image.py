"""Inspect the FAT32 subset implemented by fat32_virtual_disk.v."""

import hashlib
import pathlib
import struct


def u16(data, offset):
    return struct.unpack_from('<H', data, offset)[0]


def u32(data, offset):
    return struct.unpack_from('<I', data, offset)[0]


def read_sector(image, lba):
    image.seek(lba * 512)
    sector = image.read(512)
    if len(sector) != 512:
        raise ValueError(f'镜像缺少物理扇区 {lba}；FAT32 检查需要包含完整文件数据')
    return sector


def fat32_volume(image):
    zero = read_sector(image, 0)
    if zero[510:512] != b'\x55\xaa':
        return None
    if zero[0] in (0xeb, 0xe9):
        partition, boot = 0, zero
    elif zero[450] in (0x0b, 0x0c):
        partition = u32(zero, 454)
        boot = read_sector(image, partition)
    else:
        return None
    spc = boot[13]
    reserved = u16(boot, 14)
    fats = boot[16]
    fat_size = u32(boot, 36)
    root = u32(boot, 44) & 0x0fffffff
    if (boot[510:512] != b'\x55\xaa' or u16(boot, 11) != 512 or not spc
            or spc & (spc - 1) or not reserved or fats not in (1, 2)
            or not fat_size or root < 2):
        return None
    fat_start = partition + reserved
    data_start = fat_start + fats * fat_size

    def next_cluster(cluster):
        fat = read_sector(image, fat_start + cluster // 128)
        return u32(fat, cluster % 128 * 4) & 0x0fffffff

    def cluster_lba(cluster):
        return data_start + (cluster - 2) * spc

    return partition, spc, root, cluster_lba, next_cluster


def root_files(image, spc, root, cluster_lba, next_cluster):
    files = []
    cluster = root
    visited = set()
    sectors = 0
    bmp_count = 0
    wav_found = False
    while sectors < 128:
        if cluster < 2 or cluster >= 0x0ffffff8 or cluster in visited:
            raise ValueError('根目录簇链提前结束或循环')
        visited.add(cluster)
        for sector_in_cluster in range(spc):
            directory = read_sector(image, cluster_lba(cluster) + sector_in_cluster)
            sectors += 1
            for offset in range(0, 512, 32):
                item = directory[offset:offset + 32]
                if item[0] == 0 or (bmp_count == 4 and wav_found):
                    return files
                attr = item[11]
                if item[0] == 0xe5 or attr == 0x0f or attr & 0x18:
                    continue
                first = (u16(item, 20) << 16) | u16(item, 26)
                size = u32(item, 28)
                kind = item[8:11]
                if first < 2:
                    continue
                if kind == b'BMP' and size >= 54 and bmp_count < 4:
                    bmp_count += 1
                elif kind == b'WAV' and size >= 44 and not wav_found:
                    wav_found = True
                else:
                    continue
                name = item[:8].decode('ascii', 'replace').rstrip()
                files.append((f'{name}.{kind.decode("ascii")}', kind, first, size))
            if sectors >= 128:
                return files
        cluster = next_cluster(cluster)
        if cluster >= 0x0ffffff8:
            return files
    return files


def file_digest(image, first, size, spc, cluster_lba, next_cluster):
    cluster = first
    visited = set()
    digest = hashlib.sha256()
    header = bytearray()
    remaining = size
    while remaining:
        if cluster < 2 or cluster >= 0x0ffffff8 or cluster in visited:
            raise ValueError(f'文件簇链提前结束或循环，剩余 {remaining} 字节')
        visited.add(cluster)
        for sector_in_cluster in range(spc):
            if not remaining:
                break
            chunk = read_sector(image, cluster_lba(cluster) + sector_in_cluster)
            chunk = chunk[:min(remaining, 512)]
            digest.update(chunk)
            if len(header) < 64:
                header.extend(chunk[:64 - len(header)])
            remaining -= len(chunk)
        if remaining:
            cluster = next_cluster(cluster)
    return digest.hexdigest(), bytes(header)


def check_fat32_image(image, reference_paths):
    volume = fat32_volume(image)
    if volume is None:
        return None
    partition, spc, root, cluster_lba, next_cluster = volume
    references = {}
    for path in reference_paths:
        data = pathlib.Path(path).read_bytes()
        references[hashlib.sha256(data).hexdigest()] = pathlib.Path(path).name
    try:
        files = root_files(image, spc, root, cluster_lba, next_cluster)
        bmp_count = 0
        wav_count = 0
        good = bool(references)
        print(f'FAT32 分区起始扇区 {partition}，每簇 {spc} 扇区')
        for name, kind, first, size in files:
            digest, header = file_digest(image, first, size, spc, cluster_lba, next_cluster)
            if kind == b'BMP':
                bmp_count += 1
                valid = (header[:2] == b'BM' and
                         (u32(header, 18), u32(header, 22)) in
                         ((320, 180), (320, 240), (640, 480), (1280, 960)) and
                         u16(header, 28) == 24 and u32(header, 30) == 0)
            else:
                wav_count += 1
                valid = (header[:4] == b'RIFF' and header[8:12] == b'WAVE' and
                         header[12:16] == b'fmt ' and u16(header, 20) == 1 and
                         u16(header, 22) == 2 and u32(header, 24) == 48000 and
                         u16(header, 34) == 16 and header[36:40] == b'data' and
                         (u32(header, 40) >> 2) >= 256)
            match = references.get(digest, '(未提供匹配的对照文件)')
            print(f'  {name}: {size} 字节，簇 {first}，格式 {"OK" if valid else "不支持"}，对照 {match}')
            good &= valid and digest in references
        good &= 1 <= bmp_count <= 4 and wav_count == 1
    except ValueError as exc:
        print(f'FAT32 检查失败：{exc}')
        return False
    print('VERIFY PASS' if good else 'VERIFY FAIL')
    return good
