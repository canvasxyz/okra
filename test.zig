const std = @import("std");
const expect = std.testing.expect;

const Tree = @import("./src/tree.zig").Tree;
const Page = @import("./src/page.zig").Page;
const Leaf = @import("./src/leaf.zig").Leaf;

const constants = @import("./src/constants.zig");

test "insert leaves into a single page" {
  const a = try Leaf.parse("01:ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb");
  const b = try Leaf.parse("02:3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d");
  const c = try Leaf.parse("03:2e7d2c03a9507ae265ecf5b5356885a53393a2029d241394997265a1a25aefc6");

  const z = try Leaf.parse("18446744073709551615:00");

  const tree = try Tree.temp(constants.DEFAULT_MEMORY_STORE_PAGE_LIMIT);

  try tree.insert(&b);
  try tree.insert(&a);
  try tree.insert(&c);

  try expect(tree.header.get_page_count() == 1);
  try expect(tree.header.get_leaf_count() == 4);
  try expect(tree.page_id == tree.header.get_root_id());

  try expect(tree.page.eql(&Page.create(Leaf, 0, &[_]Leaf{a, b, c, z}, 0)));

  tree.close();
}

test "insert leaves into a list of pages" {
  const tree = try Tree.temp(constants.DEFAULT_MEMORY_STORE_PAGE_LIMIT);

  const a = try Leaf.parse("01:ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb");
  const b = try Leaf.parse("02:3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d");
  const c = try Leaf.parse("03:2e7d2c03a9507ae265ecf5b5356885a53393a2029d241394997265a1a25aefc6");
  const d = try Leaf.parse("04:18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4");
  const e = try Leaf.parse("05:3f79bb7b435b05321651daefd374cdc681dc06faa65e374e38337b88ca046dea");
  const f = try Leaf.parse("06:252f10c83610ebca1a059c0bae8255eba2f95be4d1d7bcfa89d7248a82d9f111");
  const g = try Leaf.parse("07:cd0aa9856147b6c5b4ff2b7dfee5da20aa38253099ef1b4a64aced233c9afe29");
  const h = try Leaf.parse("08:aaa9402664f1a41f40ebbc52c9993eb66aeb366602958fdfaa283b71e64db123");
  const i = try Leaf.parse("09:de7d1b721a1e0632b7cf04edf5032c8ecffa9f9a08492152b926f1a5a7e765d7");
  const j = try Leaf.parse("10:189f40034be7a199f1fa9891668ee3ab6049f82d38c68be70f596eab2e1857b7");
  const k = try Leaf.parse("11:8254c329a92850f6d539dd376f4816ee2764517da5e0235514af433164480d7a");
  const l = try Leaf.parse("12:acac86c0e609ca906f632b0e2dacccb2b77d22b0621f20ebece1a4835b93f6f0");
  const m = try Leaf.parse("13:62c66a7a5dd70c3146618063c344e531e6d4b59e379808443ce962b3abd63c5a");

  const z = try Leaf.parse("18446744073709551615:00");

  try tree.insert(&e);
  try tree.insert(&c);
  try tree.insert(&m);
  try tree.insert(&g);
  try tree.insert(&b);
  try tree.insert(&f);
  try tree.insert(&k);
  try tree.insert(&d);
  try tree.insert(&h);
  try tree.insert(&a);
  try tree.insert(&j);
  try tree.insert(&l);
  try tree.insert(&i);
  
  try expect(tree.header.get_page_count() == 3);
  try expect(tree.header.get_leaf_count() == 14);

  if (tree.memory_store) |memory_store| {
    try expect(memory_store.get_page(1).eql(
      &Page.create(Leaf, 0, &[_]Leaf{a, b, c, d, e, f}, 2)
    ));

    try expect(memory_store.get_page(2).eql(
      &Page.create(Leaf, 0, &[_]Leaf{g, h, i, j, k, l}, 3)
    ));

    try expect(memory_store.get_page(3).eql(
      &Page.create(Leaf, 0, &[_]Leaf{m, z}, 0)
    ));
  } else {
    @panic("aaaa");
  }

  tree.close();
}