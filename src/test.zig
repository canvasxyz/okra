const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Sha256 = std.crypto.hash.sha2.Sha256;

const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");

const Tree = @import("./tree.zig").Tree;
const Builder = @import("./builder.zig").Builder;

const utils = @import("./utils.zig");

const Options = struct {
  mapSize: usize = 10485760,
};

fn testPermutations(comptime X: usize, comptime Q: u8, comptime N: usize, permutations: []const [N]u16, options: Options) !void {
  const stdout = std.io.getStdOut().writer();
  try stdout.print("\n", .{});

  var tmp = std.testing.tmpDir(.{});

  const referencePath = try utils.resolvePath(allocator, tmp.dir, "reference.mdb");
  defer allocator.free(referencePath);
  var builder = try Builder(X, Q).init(referencePath, .{ .mapSize = options.mapSize });

  var key = [_]u8{ 0 } ** X;
  var value: [32]u8 = undefined;

  for (permutations[0]) |i| {
    std.mem.writeIntBig(u16, key[(X-2)..X], i + 1);
    Sha256.hash(&key, &value, .{});
    try builder.insert(&key, &value);
  }

  _ = try builder.finalize(null);
  const referenceEnv = try lmdb.Environment(2+X, 32).open(referencePath, .{});

  var nameBuffer: [32]u8 = undefined;
  for (permutations) |permutation, p| {
    const name = try std.fmt.bufPrint(&nameBuffer, "p{d}.{x}.mdb", .{ N, p });
    const path = try utils.resolvePath(allocator, tmp.dir, name);
    defer allocator.free(path);

    var tree: Tree(X, Q) = undefined;
    try tree.init(allocator, path, .{ .mapSize = options.mapSize, .log = null });
    for (permutation) |i| {
      std.mem.writeIntBig(u16, key[(X-2)..X], i + 1);
      Sha256.hash(&key, &value, .{});
      try tree.insert(&key, &value);
    }

    try expectEqual(@as(usize, 0), try lmdb.compareEntries(2+X, 32, referenceEnv, tree.env, .{}));
    tree.close();
  }

  referenceEnv.close();
  tmp.cleanup();
}

test "Tree(6, 0x30) on permutations of 10" {
  const permutations = [_][10]u16{
    .{4, 6, 7, 2, 5, 1, 8, 3, 9, 0},
    .{5, 0, 8, 2, 9, 3, 4, 7, 6, 1},
    .{4, 5, 8, 2, 0, 1, 6, 7, 9, 3},
    .{1, 7, 6, 5, 8, 3, 4, 2, 0, 9},
  };

  try testPermutations(6, 0x30, 10, &permutations, .{ });
}

test "Tree(6, 0x30) on permutations of 100" {
  const permutations = [_][100]u16{
    .{
      0, 74, 33, 97, 25, 91, 77, 29, 83, 1, 24, 86, 35, 11, 7, 48, 60, 21, 96, 68, 59, 12, 78, 17, 98, 43, 46, 76, 9, 73,
      85, 20, 18, 36, 82, 71, 69, 40, 92, 57, 84, 37, 45, 75, 39, 88, 87, 5, 90, 22, 2, 23, 38, 47, 65, 93, 67, 56, 30,
      34, 41, 10, 62, 8, 44, 14, 26, 51, 52, 13, 19, 53, 61, 95, 66, 64, 94, 49, 4, 55, 6, 50, 54, 79, 89, 42, 80, 27, 16,
      81, 15, 99, 70, 3, 72, 63, 28, 31, 58, 32
    },
    .{
      37, 86, 2, 59, 96, 46, 0, 18, 26, 99, 97, 61, 87, 24, 53, 28, 17, 82, 73, 41, 29, 83, 76, 74, 51, 45, 32, 30, 95,
      52, 1, 57, 39, 48, 58, 70, 89, 16, 31, 77, 60, 34, 5, 33, 54, 21, 38, 3, 40, 10, 42, 44, 75, 72, 19, 22, 15, 9, 36,
      98, 69, 55, 64, 27, 93, 49, 66, 81, 78, 11, 65, 13, 23, 68, 7, 35, 80, 47, 91, 25, 20, 71, 63, 43, 4, 94, 67, 90,
      56, 88, 79, 84, 50, 62, 14, 12, 6, 92, 85, 8
    },
    .{
      19, 55, 99, 65, 4, 71, 82, 66, 23, 68, 97, 20, 41, 63, 50, 46, 6, 31, 49, 45, 80, 58, 77, 95, 70, 60, 59, 34, 16,
      22, 7, 94, 87, 15, 72, 42, 12, 17, 1, 64, 11, 28, 69, 89, 36, 98, 18, 21, 3, 74, 0, 75, 2, 39, 62, 44, 40, 43, 79,
      84, 57, 47, 32, 30, 5, 67, 93, 27, 85, 96, 56, 13, 10, 92, 54, 37, 33, 73, 91, 38, 88, 48, 76, 35, 81, 29, 26, 90,
      51, 78, 14, 9, 52, 8, 25, 83, 24, 61, 53, 86
    },
    .{
      88, 23, 26, 0, 56, 16, 53, 15, 81, 27, 45, 77, 44, 12, 43, 59, 3, 96, 61, 29, 65, 47, 40, 70, 64, 19, 36, 84, 69,
      83, 66, 74, 86, 48, 71, 14, 25, 49, 28, 41, 38, 13, 21, 10, 1, 57, 95, 52, 80, 34, 79, 50, 32, 4, 33, 72, 7, 75, 62,
      31, 35, 17, 89, 51, 91, 93, 5, 97, 46, 18, 68, 37, 55, 22, 6, 76, 87, 98, 58, 20, 9, 42, 94, 85, 63, 39, 78, 82, 60,
      90, 11, 24, 99, 30, 8, 54, 2, 67, 73, 92
    },
  };

  try testPermutations(6, 0x30, 100, &permutations, .{});
}

test "Tree(6, 0x30) on permutations of 1000" {
  const permutations = [_][1000]u16{
    .{
      921, 66, 52, 37, 729, 984, 275, 690, 654, 810, 869, 226, 946, 430, 345, 768, 286, 914, 440, 30, 694, 666, 236, 811,
      728, 395, 73, 890, 142, 863, 5, 708, 758, 153, 4, 248, 425, 849, 664, 246, 69, 489, 594, 369, 560, 1, 452, 192, 478,
      794, 671, 569, 526, 197, 734, 649, 781, 435, 853, 608, 180, 166, 571, 120, 855, 189, 95, 118, 509, 392, 154, 839,
      107, 808, 303, 479, 447, 370, 418, 637, 961, 322, 229, 725, 752, 105, 773, 57, 280, 414, 106, 199, 93, 897, 391,
      259, 385, 124, 473, 168, 523, 832, 337, 601, 211, 11, 858, 639, 838, 234, 943, 660, 701, 603, 981, 986, 974, 270,
      732, 532, 85, 42, 472, 850, 659, 619, 455, 937, 982, 360, 879, 483, 857, 927, 301, 276, 71, 383, 119, 60, 504, 590,
      495, 536, 856, 598, 552, 587, 895, 396, 704, 581, 18, 40, 538, 476, 940, 3, 766, 254, 826, 228, 868, 567, 990, 344,
      809, 333, 724, 969, 406, 115, 945, 35, 308, 51, 300, 349, 420, 393, 791, 900, 682, 641, 626, 136, 487, 177, 767,
      932, 847, 75, 824, 191, 46, 911, 62, 223, 24, 298, 14, 843, 281, 735, 98, 497, 642, 662, 783, 401, 203, 140, 436,
      292, 212, 570, 888, 775, 485, 380, 656, 409, 881, 23, 410, 933, 198, 49, 891, 746, 906, 837, 740, 244, 417, 675, 79,
      896, 141, 923, 970, 707, 920, 128, 210, 545, 689, 743, 615, 438, 994, 328, 25, 434, 260, 975, 510, 816, 779, 264,
      83, 457, 959, 411, 15, 583, 919, 373, 321, 7, 665, 916, 635, 87, 997, 797, 647, 493, 91, 988, 470, 823, 148, 366,
      661, 13, 962, 102, 415, 540, 394, 812, 453, 342, 31, 551, 835, 187, 777, 691, 332, 801, 319, 644, 352, 595, 214, 9,
      16, 756, 239, 45, 237, 64, 866, 182, 256, 29, 527, 607, 762, 668, 845, 924, 257, 282, 471, 428, 444, 751, 874, 537,
      445, 877, 800, 836, 589, 972, 806, 343, 442, 588, 507, 885, 350, 19, 6, 631, 755, 101, 368, 605, 770, 623, 776, 864,
      698, 930, 317, 750, 818, 822, 646, 681, 902, 186, 377, 8, 745, 109, 893, 170, 160, 204, 929, 684, 512, 686, 568,
      449, 458, 104, 934, 563, 657, 954, 880, 678, 492, 761, 846, 288, 956, 785, 130, 108, 648, 331, 162, 578, 886, 553,
      676, 539, 450, 310, 604, 437, 688, 424, 54, 519, 208, 865, 976, 347, 327, 634, 99, 174, 577, 265, 399, 94, 828, 592,
      324, 912, 405, 376, 710, 796, 817, 719, 146, 851, 116, 232, 854, 617, 928, 925, 419, 499, 242, 466, 548, 103, 702,
      330, 304, 81, 544, 935, 247, 565, 121, 129, 240, 834, 716, 543, 290, 703, 490, 89, 407, 305, 848, 820, 357, 151, 56,
      528, 185, 421, 378, 12, 748, 915, 299, 267, 158, 117, 135, 769, 788, 76, 230, 65, 611, 926, 48, 86, 531, 17, 475,
      502, 547, 250, 400, 620, 294, 696, 859, 803, 831, 714, 985, 610, 92, 200, 674, 131, 224, 670, 184, 652, 175, 993,
      367, 978, 904, 361, 456, 439, 525, 653, 559, 996, 297, 266, 699, 780, 908, 754, 715, 723, 550, 977, 793, 561, 178,
      535, 252, 34, 351, 625, 844, 112, 876, 268, 137, 441, 20, 778, 77, 277, 426, 898, 918, 636, 712, 645, 389, 113, 713,
      983, 556, 320, 573, 176, 786, 0, 427, 127, 718, 278, 390, 296, 814, 165, 878, 443, 274, 32, 917, 222, 269, 340, 516,
      227, 78, 580, 193, 374, 757, 217, 938, 138, 126, 375, 171, 958, 159, 38, 999, 194, 422, 711, 315, 784, 618, 616,
      790, 59, 736, 518, 805, 358, 285, 464, 283, 251, 720, 33, 873, 486, 253, 875, 687, 524, 960, 416, 408, 546, 262,
      235, 468, 423, 582, 614, 968, 314, 705, 334, 862, 312, 50, 72, 173, 382, 461, 613, 606, 97, 738, 372, 749, 887, 365,
      612, 149, 655, 989, 883, 558, 215, 804, 789, 467, 833, 871, 27, 979, 111, 541, 67, 429, 575, 771, 325, 827, 61, 909,
      602, 96, 311, 309, 949, 295, 554, 388, 53, 318, 922, 731, 852, 727, 591, 861, 744, 110, 953, 683, 249, 169, 188,
      167, 576, 505, 520, 957, 998, 44, 973, 695, 829, 627, 533, 722, 596, 245, 600, 231, 787, 28, 10, 907, 134, 651, 238,
      371, 379, 980, 326, 355, 152, 501, 901, 431, 905, 68, 474, 243, 515, 164, 609, 469, 658, 147, 209, 807, 293, 542,
      574, 302, 709, 462, 944, 513, 640, 63, 995, 692, 813, 939, 26, 498, 307, 680, 963, 2, 313, 950, 628, 218, 522, 179,
      74, 942, 384, 336, 381, 913, 821, 579, 903, 882, 353, 593, 500, 454, 157, 70, 47, 948, 679, 488, 508, 386, 841, 952,
      700, 529, 564, 685, 496, 872, 530, 599, 359, 362, 258, 206, 842, 650, 90, 622, 572, 629, 404, 638, 323, 534, 630,
      965, 503, 225, 621, 125, 233, 459, 477, 632, 289, 884, 798, 677, 219, 341, 899, 597, 433, 517, 967, 161, 207, 555,
      991, 931, 815, 889, 739, 181, 273, 55, 287, 964, 205, 951, 484, 987, 195, 163, 446, 356, 271, 261, 39, 354, 585,
      364, 291, 84, 673, 795, 133, 80, 221, 733, 216, 549, 971, 202, 774, 772, 482, 669, 284, 759, 21, 506, 494, 870, 172,
      397, 144, 132, 201, 737, 255, 693, 992, 36, 403, 413, 306, 726, 802, 840, 241, 465, 448, 402, 432, 220, 279, 412,
      114, 329, 335, 753, 819, 830, 741, 521, 765, 338, 143, 190, 511, 481, 263, 123, 697, 941, 150, 339, 145, 894, 667,
      764, 867, 586, 196, 100, 760, 41, 910, 82, 966, 717, 624, 742, 348, 747, 663, 584, 155, 58, 892, 557, 122, 213, 706,
      955, 139, 947, 88, 491, 156, 799, 480, 363, 463, 43, 763, 316, 183, 825, 398, 566, 792, 22, 672, 782, 387, 460, 346,
      860, 633, 936, 272, 562, 721, 451, 643, 730, 514
    },
    .{
      726, 548, 374, 938, 340, 804, 30, 417, 919, 653, 260, 736, 27, 621, 245, 184, 476, 896, 810, 427, 258, 23, 337, 452,
      875, 92, 744, 755, 691, 659, 951, 50, 139, 191, 864, 898, 180, 872, 237, 840, 687, 148, 136, 980, 61, 231, 28, 153,
      890, 636, 698, 966, 880, 499, 958, 119, 134, 57, 540, 693, 380, 837, 852, 854, 112, 883, 635, 410, 547, 562, 607,
      829, 225, 830, 40, 373, 982, 930, 603, 288, 696, 296, 881, 359, 602, 360, 304, 429, 159, 114, 874, 827, 248, 97,
      346, 358, 848, 756, 37, 36, 303, 900, 721, 421, 531, 552, 59, 730, 431, 323, 266, 384, 181, 566, 895, 493, 453, 537,
      550, 522, 984, 711, 909, 699, 372, 760, 825, 792, 463, 338, 596, 273, 424, 665, 967, 161, 675, 942, 707, 220, 679,
      782, 401, 927, 891, 876, 642, 333, 861, 511, 708, 873, 641, 293, 529, 828, 282, 517, 459, 208, 256, 677, 109, 90,
      170, 611, 432, 171, 753, 227, 528, 809, 439, 710, 934, 777, 787, 832, 542, 991, 73, 599, 932, 408, 480, 271, 287,
      591, 229, 774, 870, 311, 662, 420, 772, 392, 302, 953, 155, 849, 176, 608, 193, 860, 21, 458, 995, 632, 13, 815, 46,
      578, 768, 100, 483, 843, 88, 704, 757, 546, 331, 761, 776, 785, 2, 717, 918, 472, 812, 48, 326, 791, 397, 889, 279,
      584, 261, 264, 143, 150, 523, 179, 393, 862, 121, 435, 71, 295, 784, 381, 897, 202, 9, 10, 819, 798, 301, 808, 668,
      398, 656, 488, 948, 309, 353, 914, 43, 259, 319, 199, 298, 5, 722, 983, 725, 535, 767, 935, 278, 272, 324, 32, 573,
      667, 484, 643, 961, 807, 748, 619, 564, 442, 255, 11, 394, 129, 325, 426, 125, 524, 571, 1, 514, 666, 561, 18, 956,
      781, 450, 887, 391, 495, 567, 728, 648, 821, 624, 448, 910, 976, 468, 507, 162, 783, 594, 823, 74, 771, 422, 328,
      582, 749, 839, 78, 216, 418, 188, 457, 135, 906, 541, 127, 630, 487, 501, 399, 190, 192, 197, 992, 884, 54, 615,
      365, 364, 568, 405, 606, 669, 318, 31, 123, 838, 224, 899, 369, 175, 929, 69, 205, 766, 586, 811, 505, 281, 539,
      351, 670, 954, 850, 556, 673, 617, 285, 201, 978, 110, 91, 510, 204, 39, 240, 597, 230, 433, 313, 565, 6, 145, 715,
      960, 213, 857, 788, 154, 322, 286, 368, 996, 142, 558, 7, 931, 447, 988, 183, 502, 979, 312, 455, 950, 943, 38, 516,
      690, 723, 178, 20, 805, 509, 294, 922, 712, 355, 257, 965, 921, 482, 613, 122, 778, 964, 936, 465, 441, 118, 901,
      389, 575, 63, 307, 51, 494, 915, 538, 218, 692, 473, 267, 533, 695, 275, 816, 492, 952, 577, 341, 957, 163, 434,
      905, 77, 471, 470, 58, 489, 49, 674, 141, 242, 869, 504, 147, 496, 847, 25, 734, 428, 530, 210, 265, 626, 363, 335,
      130, 214, 299, 581, 745, 274, 762, 703, 652, 770, 962, 802, 404, 168, 851, 525, 349, 985, 949, 481, 924, 902, 187,
      101, 885, 610, 62, 557, 553, 620, 688, 993, 713, 724, 545, 370, 167, 834, 289, 436, 72, 75, 80, 157, 55, 438, 759,
      169, 250, 332, 592, 196, 947, 638, 559, 818, 612, 87, 460, 462, 803, 637, 683, 316, 198, 345, 863, 84, 233, 103,
      344, 407, 661, 105, 937, 52, 269, 763, 376, 68, 475, 820, 146, 419, 882, 526, 387, 877, 518, 469, 56, 633, 742, 560,
      132, 689, 765, 270, 855, 858, 329, 779, 93, 276, 400, 290, 207, 423, 186, 67, 968, 390, 76, 89, 437, 0, 254, 579,
      402, 212, 189, 165, 342, 989, 998, 933, 194, 705, 714, 166, 310, 563, 997, 645, 375, 833, 474, 140, 406, 817, 354,
      508, 678, 790, 268, 605, 904, 152, 513, 663, 972, 651, 195, 120, 801, 520, 444, 720, 773, 797, 262, 82, 975, 247,
      731, 650, 856, 813, 733, 973, 846, 676, 786, 236, 226, 131, 892, 879, 913, 45, 826, 29, 385, 137, 172, 534, 589,
      486, 185, 228, 519, 124, 283, 356, 334, 955, 44, 252, 649, 3, 445, 12, 640, 588, 479, 893, 498, 366, 664, 814, 775,
      477, 53, 79, 671, 16, 718, 99, 200, 842, 173, 386, 209, 799, 314, 85, 466, 758, 116, 253, 551, 941, 928, 746, 639,
      246, 241, 684, 107, 769, 174, 680, 33, 223, 868, 609, 102, 96, 959, 388, 622, 527, 716, 34, 403, 618, 544, 795, 206,
      794, 911, 238, 836, 464, 263, 106, 971, 925, 215, 339, 999, 647, 160, 83, 694, 806, 158, 702, 939, 113, 709, 300,
      743, 440, 42, 315, 831, 413, 235, 291, 81, 576, 587, 764, 343, 944, 485, 94, 249, 747, 719, 569, 590, 543, 297, 841,
      871, 923, 822, 416, 917, 727, 706, 478, 277, 634, 348, 305, 395, 251, 793, 497, 845, 239, 133, 903, 644, 865, 824,
      946, 623, 8, 308, 646, 835, 95, 970, 732, 117, 320, 628, 24, 443, 697, 780, 491, 867, 701, 411, 217, 182, 412, 853,
      66, 371, 461, 878, 604, 330, 572, 347, 415, 317, 243, 555, 221, 940, 920, 987, 17, 425, 521, 740, 378, 682, 583, 4,
      532, 655, 467, 796, 977, 866, 414, 672, 570, 35, 536, 22, 735, 350, 908, 490, 19, 593, 306, 738, 15, 327, 990, 681,
      115, 750, 515, 126, 151, 660, 574, 631, 625, 382, 916, 449, 454, 686, 789, 554, 595, 657, 284, 907, 222, 963, 994,
      446, 754, 598, 969, 128, 280, 156, 859, 685, 500, 377, 549, 60, 41, 361, 600, 219, 244, 512, 729, 65, 616, 629, 430,
      506, 658, 64, 47, 912, 396, 981, 585, 700, 800, 138, 580, 367, 234, 601, 456, 177, 451, 974, 149, 111, 752, 741,
      383, 232, 144, 751, 409, 926, 321, 357, 104, 894, 503, 614, 379, 86, 739, 98, 654, 164, 627, 945, 888, 844, 352,
      292, 737, 26, 211, 336, 203, 108, 886, 70, 986, 362, 14
    },
    .{
      639, 520, 352, 687, 117, 502, 765, 398, 234, 272, 116, 958, 804, 432, 277, 921, 905, 772, 297, 42, 818, 621, 291,
      556, 861, 866, 548, 470, 417, 362, 290, 399, 244, 201, 72, 816, 73, 451, 173, 647, 438, 963, 33, 674, 803, 168, 142,
      791, 494, 651, 317, 318, 221, 425, 726, 111, 136, 623, 436, 53, 400, 500, 776, 164, 917, 514, 956, 538, 82, 56, 902,
      34, 251, 705, 666, 30, 118, 343, 527, 718, 685, 132, 66, 794, 305, 157, 841, 620, 397, 283, 872, 180, 265, 106, 922,
      294, 599, 840, 487, 580, 773, 884, 549, 267, 62, 129, 341, 986, 462, 79, 822, 228, 755, 379, 894, 372, 752, 993,
      433, 589, 211, 516, 281, 911, 319, 938, 150, 839, 683, 591, 403, 22, 454, 837, 790, 493, 829, 710, 656, 677, 473,
      741, 366, 996, 707, 422, 410, 667, 573, 859, 134, 880, 531, 595, 355, 708, 5, 786, 261, 682, 337, 879, 579, 766,
      335, 264, 477, 63, 792, 680, 637, 389, 871, 367, 333, 300, 598, 325, 554, 456, 980, 962, 645, 937, 852, 668, 411,
      629, 23, 977, 295, 288, 885, 447, 45, 145, 161, 559, 498, 744, 926, 846, 133, 51, 723, 515, 172, 427, 31, 383, 204,
      957, 593, 513, 906, 689, 29, 583, 469, 418, 465, 844, 338, 679, 171, 222, 99, 330, 611, 194, 444, 67, 865, 584, 681,
      614, 761, 507, 745, 446, 995, 650, 654, 441, 785, 191, 959, 253, 553, 287, 899, 401, 860, 501, 69, 159, 546, 351,
      213, 230, 148, 925, 853, 65, 987, 4, 268, 730, 855, 1, 202, 196, 870, 374, 44, 923, 932, 149, 435, 848, 39, 484,
      793, 357, 826, 138, 935, 105, 782, 990, 162, 924, 780, 669, 141, 199, 947, 11, 452, 784, 756, 971, 876, 107, 94,
      964, 907, 703, 635, 316, 499, 896, 529, 814, 535, 537, 126, 953, 345, 753, 218, 771, 892, 528, 691, 834, 673, 13,
      120, 382, 867, 981, 954, 676, 26, 231, 464, 965, 561, 933, 127, 742, 631, 616, 897, 970, 578, 472, 734, 309, 895,
      985, 463, 273, 898, 467, 232, 391, 641, 512, 321, 901, 323, 625, 114, 989, 851, 279, 572, 3, 38, 203, 991, 312, 254,
      587, 174, 392, 235, 349, 123, 310, 966, 649, 757, 982, 592, 702, 187, 431, 347, 102, 407, 886, 250, 12, 541, 243,
      486, 21, 912, 496, 659, 858, 344, 495, 862, 81, 811, 206, 365, 698, 787, 220, 450, 802, 833, 778, 716, 298, 622,
      751, 414, 393, 798, 128, 59, 205, 795, 891, 348, 190, 916, 40, 385, 270, 868, 370, 760, 628, 588, 188, 944, 770,
      915, 74, 43, 260, 711, 823, 276, 849, 207, 699, 27, 976, 404, 694, 459, 155, 613, 124, 724, 942, 517, 719, 440, 847,
      154, 396, 759, 788, 653, 633, 566, 364, 874, 569, 48, 927, 14, 147, 657, 519, 998, 359, 54, 412, 322, 934, 37, 437,
      324, 920, 975, 223, 140, 864, 103, 544, 377, 388, 612, 169, 873, 807, 83, 197, 121, 471, 931, 646, 415, 777, 381,
      409, 360, 481, 836, 166, 200, 609, 153, 90, 86, 574, 17, 758, 863, 746, 845, 672, 160, 626, 256, 696, 143, 327, 721,
      258, 881, 941, 420, 356, 732, 658, 237, 576, 988, 831, 238, 311, 979, 460, 857, 665, 800, 110, 738, 596, 828, 156,
      690, 972, 144, 693, 586, 245, 390, 739, 701, 308, 565, 796, 940, 900, 642, 225, 302, 112, 813, 242, 543, 618, 518,
      582, 430, 57, 830, 671, 78, 999, 289, 113, 210, 552, 607, 883, 943, 764, 331, 550, 18, 50, 904, 968, 482, 98, 664,
      428, 20, 564, 130, 212, 216, 974, 457, 577, 358, 274, 908, 179, 747, 378, 328, 405, 189, 249, 167, 178, 32, 16, 715,
      994, 269, 419, 506, 259, 224, 125, 139, 92, 485, 2, 827, 973, 299, 608, 122, 85, 660, 77, 146, 476, 93, 442, 731,
      709, 558, 887, 601, 617, 104, 89, 342, 313, 461, 838, 181, 423, 226, 491, 648, 75, 567, 889, 55, 88, 64, 28, 820,
      644, 70, 948, 594, 946, 878, 695, 52, 346, 443, 643, 24, 95, 675, 282, 684, 292, 797, 195, 740, 733, 247, 663, 686,
      817, 314, 768, 821, 49, 783, 184, 119, 100, 781, 610, 748, 597, 61, 227, 424, 275, 177, 421, 278, 332, 714, 9, 10,
      165, 334, 158, 928, 492, 263, 354, 774, 526, 700, 87, 533, 725, 429, 949, 386, 545, 735, 893, 634, 877, 706, 394,
      805, 468, 799, 0, 503, 808, 416, 285, 918, 303, 339, 534, 704, 353, 255, 350, 978, 638, 434, 336, 340, 361, 109,
      562, 952, 248, 271, 810, 7, 96, 636, 661, 510, 717, 692, 368, 815, 910, 163, 779, 239, 376, 406, 536, 930, 603, 555,
      262, 236, 320, 209, 208, 605, 824, 754, 568, 8, 951, 602, 869, 530, 903, 375, 58, 655, 182, 186, 640, 426, 455, 175,
      619, 888, 522, 624, 630, 571, 266, 525, 489, 480, 914, 850, 413, 466, 151, 508, 532, 301, 306, 387, 41, 585, 329,
      560, 806, 35, 101, 697, 458, 743, 767, 183, 380, 789, 217, 448, 6, 524, 563, 293, 219, 551, 955, 408, 632, 590, 80,
      36, 252, 775, 214, 449, 176, 246, 812, 453, 652, 950, 542, 890, 600, 131, 960, 280, 19, 84, 25, 825, 497, 819, 722,
      969, 688, 474, 108, 304, 284, 604, 728, 198, 929, 68, 729, 91, 615, 540, 945, 439, 539, 315, 363, 71, 402, 152, 983,
      854, 939, 509, 490, 678, 662, 961, 240, 570, 478, 192, 523, 193, 670, 720, 909, 575, 257, 369, 511, 60, 233, 936,
      241, 215, 713, 801, 504, 856, 135, 76, 307, 479, 984, 326, 882, 843, 475, 46, 997, 483, 286, 913, 395, 373, 384,
      749, 296, 736, 137, 750, 737, 15, 727, 809, 115, 762, 919, 557, 229, 488, 832, 842, 606, 47, 185, 521, 581, 505,
      627, 97, 547, 445, 170, 712, 763, 875, 967, 835, 371, 769, 992
    },
    .{
      250, 371, 920, 543, 549, 138, 16, 834, 460, 188, 333, 541, 486, 365, 343, 487, 940, 38, 963, 67, 323, 43, 592, 253,
      848, 437, 49, 824, 896, 108, 298, 635, 294, 375, 738, 932, 276, 741, 753, 607, 192, 312, 429, 861, 651, 167, 115,
      757, 580, 418, 271, 111, 228, 359, 624, 37, 794, 554, 886, 233, 153, 403, 263, 764, 463, 191, 760, 632, 398, 663,
      832, 280, 608, 599, 384, 351, 897, 183, 381, 82, 185, 680, 524, 337, 587, 147, 577, 72, 370, 611, 643, 395, 122,
      338, 893, 105, 850, 806, 954, 10, 386, 490, 342, 278, 682, 293, 829, 521, 840, 614, 514, 734, 557, 532, 709, 746,
      950, 519, 688, 101, 678, 121, 535, 974, 334, 855, 22, 329, 573, 152, 320, 66, 71, 507, 316, 244, 327, 602, 537, 35,
      361, 863, 641, 64, 676, 600, 265, 252, 534, 548, 353, 876, 528, 287, 581, 126, 181, 204, 413, 249, 39, 899, 407,
      949, 179, 793, 89, 495, 970, 60, 849, 462, 144, 289, 283, 758, 8, 979, 136, 510, 625, 805, 305, 595, 529, 26, 232,
      841, 218, 420, 996, 367, 879, 363, 977, 622, 645, 807, 504, 4, 924, 483, 560, 254, 129, 311, 520, 761, 567, 114, 11,
      918, 650, 213, 522, 992, 417, 967, 349, 284, 679, 139, 489, 17, 2, 649, 385, 990, 110, 681, 93, 819, 19, 133, 891,
      441, 214, 62, 401, 96, 227, 15, 172, 366, 475, 198, 94, 180, 565, 947, 478, 553, 786, 801, 800, 512, 856, 347, 100,
      693, 242, 857, 872, 102, 864, 691, 57, 951, 648, 457, 895, 763, 989, 518, 684, 988, 631, 95, 844, 446, 703, 282,
      552, 360, 399, 604, 505, 739, 603, 860, 484, 473, 847, 556, 720, 728, 279, 582, 721, 877, 91, 425, 745, 98, 952,
      189, 686, 639, 516, 789, 256, 777, 317, 77, 646, 444, 267, 882, 705, 431, 723, 493, 270, 222, 170, 987, 574, 391,
      165, 75, 652, 408, 593, 130, 933, 694, 207, 173, 799, 307, 991, 539, 830, 792, 945, 508, 628, 966, 143, 261, 251,
      393, 465, 511, 964, 454, 7, 229, 223, 509, 500, 619, 831, 202, 477, 530, 496, 637, 264, 638, 912, 178, 419, 99, 296,
      523, 980, 427, 839, 321, 301, 149, 904, 903, 309, 277, 216, 24, 785, 957, 157, 803, 74, 272, 659, 586, 609, 526,
      322, 562, 772, 9, 545, 125, 958, 633, 868, 377, 306, 224, 341, 217, 730, 453, 544, 84, 742, 822, 536, 87, 208, 491,
      605, 959, 382, 700, 814, 445, 456, 923, 380, 578, 795, 58, 660, 350, 266, 769, 867, 929, 106, 559, 458, 56, 714,
      336, 737, 889, 304, 318, 451, 717, 83, 55, 640, 488, 767, 90, 485, 627, 853, 630, 362, 340, 177, 376, 675, 707, 750,
      209, 589, 838, 888, 982, 969, 748, 852, 319, 973, 817, 930, 941, 25, 716, 955, 59, 275, 620, 455, 104, 656, 729,
      687, 558, 326, 919, 358, 915, 124, 851, 770, 168, 883, 187, 142, 219, 743, 76, 859, 288, 467, 131, 416, 328, 156,
      146, 820, 774, 389, 812, 414, 117, 310, 653, 563, 30, 858, 568, 727, 145, 80, 533, 708, 726, 297, 302, 701, 655,
      575, 404, 45, 986, 155, 135, 907, 845, 719, 68, 865, 590, 61, 392, 811, 47, 195, 345, 668, 692, 63, 869, 928, 442,
      447, 842, 448, 344, 771, 247, 597, 925, 210, 159, 3, 51, 182, 231, 664, 132, 23, 432, 616, 36, 710, 910, 870, 779,
      584, 372, 917, 374, 960, 357, 150, 240, 291, 740, 871, 243, 698, 866, 163, 965, 615, 481, 942, 184, 226, 900, 837,
      396, 364, 862, 702, 257, 387, 197, 269, 112, 547, 120, 984, 780, 667, 732, 248, 18, 40, 775, 325, 776, 566, 916,
      571, 273, 383, 506, 169, 642, 791, 887, 200, 29, 421, 677, 128, 85, 898, 833, 873, 54, 308, 636, 290, 255, 816, 206,
      517, 469, 787, 390, 235, 440, 540, 696, 330, 937, 670, 909, 471, 299, 527, 601, 538, 303, 97, 161, 426, 331, 531,
      931, 423, 315, 613, 352, 995, 699, 783, 612, 212, 985, 230, 137, 773, 292, 892, 346, 908, 499, 459, 572, 695, 119,
      583, 724, 424, 610, 735, 993, 201, 354, 525, 711, 123, 671, 468, 21, 476, 1, 815, 943, 854, 470, 238, 885, 905, 237,
      804, 768, 449, 258, 617, 466, 843, 781, 890, 821, 914, 938, 400, 12, 666, 683, 704, 164, 14, 53, 92, 268, 956, 154,
      285, 968, 751, 983, 262, 86, 225, 922, 661, 335, 588, 234, 756, 997, 107, 314, 176, 975, 962, 295, 901, 634, 569,
      755, 809, 674, 561, 13, 502, 175, 981, 953, 606, 472, 281, 828, 825, 221, 762, 474, 921, 550, 778, 160, 313, 259,
      174, 551, 712, 788, 564, 52, 70, 796, 546, 28, 438, 626, 697, 369, 140, 752, 190, 44, 452, 409, 33, 623, 503, 482,
      576, 450, 894, 790, 878, 439, 378, 186, 141, 402, 747, 875, 759, 725, 784, 497, 435, 927, 203, 356, 20, 48, 946,
      913, 715, 706, 542, 736, 731, 73, 31, 971, 166, 902, 50, 685, 978, 621, 818, 513, 199, 6, 765, 171, 430, 665, 972,
      368, 388, 948, 46, 936, 846, 598, 433, 480, 766, 27, 906, 808, 713, 926, 673, 515, 211, 246, 669, 220, 339, 492,
      116, 236, 88, 162, 373, 733, 934, 127, 802, 662, 241, 428, 5, 494, 782, 658, 810, 579, 797, 874, 835, 239, 205, 501,
      570, 332, 594, 689, 722, 647, 41, 412, 672, 194, 654, 134, 151, 436, 961, 32, 443, 629, 994, 113, 196, 461, 103,
      881, 718, 434, 827, 749, 397, 939, 976, 880, 411, 884, 690, 81, 422, 355, 148, 215, 69, 585, 591, 34, 158, 498, 42,
      999, 324, 410, 260, 657, 415, 813, 300, 65, 379, 998, 78, 406, 836, 79, 348, 911, 823, 0, 245, 464, 555, 644, 596,
      405, 798, 193, 109, 286, 944, 618, 394, 479, 826, 118, 935, 754, 744, 274
    }
  };

  try testPermutations(6, 0x30, 1000, &permutations, .{});
}

test "Tree(6, 0x30) on randomly shuffled permutations of 10000" {
  var permutations: [1][10000]u16 = undefined;
  var i: u16 = 0;
  while (i < 10000) : (i += 1) permutations[0][i] = i;

  var prng = std.rand.DefaultPrng.init(0x0000000000000000);
  var random = prng.random();
  std.rand.Random.shuffle(random, u16, &permutations[0]);

  try testPermutations(6, 0x30, 10000, &permutations, .{ .mapSize = 2 * 1024 * 1024 * 1024});
}
