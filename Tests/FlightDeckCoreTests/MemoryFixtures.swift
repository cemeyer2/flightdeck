// Captured tool output used by PowerToolsTests (macOS 27.2, Apple silicon). Finder was chosen because it is
// always running and holds every interesting category (heap, graphics, mapped files, code, stacks).

enum MemoryFixtures {
    /// `footprint --swapped -f bytes <Finder>`: exact byte columns, with the swapped column (part of Dirty).
    static let footprintBytes = #"""
================================================================================
Finder [894]: 64-bit    Footprint: 253248616 B (16384 bytes per page)
================================================================================

      Dirty     (Swapped)         Clean   Reclaimable    Regions    Category
        ---           ---           ---           ---        ---    ---
185139200 B    30556160 B           0 B     9895936 B        208    Malloc Small
 13254656 B     8749056 B           0 B      294912 B        378    CoreAnimation
 10305536 B    10190848 B           0 B           0 B         64    OS Alloc Once
  9781248 B     6766592 B           0 B           0 B         42    Owned physical footprint (unmapped) (graphics)
  5619712 B     5406720 B           0 B           0 B        171    CG Image
  5210112 B     5144576 B           0 B           0 B         33    CoreUI Image Data
  4046848 B     2260992 B           0 B     1146880 B         61    Untagged
  3698253 B     1354492 B      262144 B           0 B       1146    __DATA
  3165862 B      750095 B           0 B           0 B       1109    __DATA_DIRTY
  2310144 B     1851392 B           0 B     2768896 B         69    IOAccelerator (graphics)
  2244608 B      770048 B           0 B       32768 B         16    Malloc Metadata
  1753088 B     1753088 B           0 B           0 B         10    CoreServices
  1441792 B     1441792 B           0 B           0 B         20    QuickLook Thumbnails
  1193125 B      346788 B           0 B           0 B        625    __AUTH
   787560 B           0 B           0 B           0 B          1    page table
   700520 B      329809 B           0 B           0 B       2907    unused dyld shared cache area
   409600 B      409600 B           0 B           0 B        125    IOSurface
   360448 B       81920 B           0 B           0 B         10    Stack
   344064 B      327680 B           0 B       32768 B          5    Foundation
   245760 B      180224 B      671744 B           0 B       1196    __DATA_CONST
   229376 B       32768 B           0 B           0 B          1    Malloc Tiny
   212992 B      212992 B           0 B           0 B         29    Owned physical footprint (unmapped)
   131072 B      114688 B           0 B           0 B          1    Accelerate Framework
    98304 B       16384 B           0 B           0 B          3    Malloc Nano
    85944 B       36864 B           0 B           0 B          4    __TPRO_CONST
    81920 B           0 B           0 B           0 B          9    IOKit
    65536 B           0 B           0 B           0 B          2    IOAccelerator
    65536 B           0 B           0 B           0 B          1    Activity Tracing
    52808 B       16384 B           0 B           0 B          1    __OBJC_RW
    49152 B       49152 B           0 B           0 B          1    CG Raster Data
    49152 B       49152 B           0 B           0 B          3    ColorSync
    32768 B       32768 B    53936128 B           0 B        183    mapped file
    32768 B       32768 B           0 B           0 B          2    CoreImage
    32768 B           0 B           0 B           0 B          2    CoreGraphics
    16384 B           0 B           0 B           0 B          1    Deferred Reclaim
        0 B           0 B     9207808 B           0 B       1284    __TEXT
        0 B           0 B      212992 B           0 B          7    __LINKEDIT
        0 B           0 B       16384 B           0 B       1186    __AUTH_CONST
        0 B           0 B           0 B           0 B          1    __OBJC_RO
        0 B           0 B           0 B           0 B          1    __FONT_DATA
        0 B           0 B           0 B           0 B          1    Dyld Private Memory
        0 B           0 B           0 B           0 B          1    __CTF
        ---           ---           ---           ---        ---    ---
253248616 B    79265792 B    64307200 B    14172160 B      10922    TOTAL

Auxiliary data:
    phys_footprint: 253248616 B
    phys_footprint_peak: 314623056 B
"""#

    /// `vmmap --summary <Finder>`, including the MALLOC ZONE table below the region table.
    static let vmmapSummary = #"""
Process:         Finder [894]
Path:            /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
Load Address:    0x104778000
Identifier:      com.apple.finder
Version:         27.2 (1865.1.20)
Build Info:      Finder_FE-1865001020000000~1
Code Type:       ARM64E
Platform:        macOS
Parent Process:  launchd [1]
Target Type:     live task

Date/Time:       2026-11-16 13:13:11.726 -0600
Launch Time:     2026-10-29 09:45:21.910 -0500
OS Version:      macOS 27.2 (26B123)
Report Version:  7
Analysis Tool:   /usr/bin/vmmap

Physical footprint:         241.5M
Physical footprint (peak):  300.0M
Idle exit:                  untracked
----

ReadOnly portion of Libraries: Total=3.1G resident=1.4G(45%) swapped_out_or_unallocated=1.7G(55%)
Writable regions: Total=426.2M written=198.2M(46%) resident=172.4M(40%) swapped_out=50.1M(12%) unallocated=203.6M(48%)

                                   VIRTUAL RESIDENT    DIRTY  SWAPPED VOLATILE   NONVOL    EMPTY   REGION
REGION TYPE                           SIZE     SIZE     SIZE     SIZE     SIZE     SIZE     SIZE    COUNT (non-coalesced)
===========                        ======= ========    =====  ======= ========   ======    =====  =======
Accelerate Framework                  128K     128K      16K     112K       0K     128K       0K        1
Activity Tracing                      256K      64K      64K       0K       0K      64K       0K        1
AttributeGraph Data (old mapping)    2048K       0K       0K     448K       0K       0K       0K        2
CG Image                             9184K     208K     208K    5280K       0K       0K       0K      171
CG Raster Data                         48K       0K       0K      48K       0K       0K       0K        1
ColorSync                              48K       0K       0K      48K       0K       0K       0K        3
CoreAnimation                        25.2M    5136K    4400K    8544K       0K    4688K    12.3M      378
CoreGraphics                           32K      32K      32K       0K       0K       0K       0K        2
CoreImage                              32K       0K       0K      32K       0K       0K       0K        2
CoreServices                         12.2M       0K       0K    1712K       0K       0K       0K       10
CoreUI Image Data                    5088K      64K      64K    5024K       0K       0K       0K       33
Deferred Reclaim                     64.0M      16K      16K       0K       0K       0K       0K        1
Dyld Private Memory                   172K       72       72      12K       0K       0K       0K        5
Foundation                            368K      16K      16K     320K       0K       0K       0K        5
Guard                               385.0G       0K       0K       0K       0K       0K       0K        1
IOAccelerator                          64K      64K      64K       0K       0K       0K       0K        2
IOAccelerator (graphics)             9984K    2256K     448K    1808K       0K    2256K    4976K       69
IOKit                                 144K      80K      80K       0K       0K      16K       0K        9
IOSurface                            2368K     400K       0K     400K       0K     400K    1056K      125
Malloc Guard Page                    3392K       0K       0K       0K       0K       0K       0K        4         see MALLOC ZONE table below
Malloc Metadata                       896K     256K     256K     640K       0K       0K       0K        8         see MALLOC ZONE table below
Malloc Metadata metadata             2224K    1216K    1216K     112K       0K       0K       0K        4         see MALLOC ZONE table below
Malloc Nano metadata                   96K      80K      80K      16K       0K       0K       0K        3         see MALLOC ZONE table below
Malloc Small                        217.5M   154.6M   147.3M    28.8M       0K       0K       0K      863         see MALLOC ZONE table below
Malloc Small (empty)                 38.5M    2144K    1072K     400K       0K       0K       0K      115         see MALLOC ZONE table below
Malloc Tiny                          4096K     192K     192K      32K       0K       0K       0K        1         see MALLOC ZONE table below
OS Alloc Once                        10.1M     112K     112K    9952K       0K       0K       0K       64
QuickLook Thumbnails                 1408K       0K       0K    1408K       0K       0K       0K       20
Stack                                10.6M     320K     288K      80K       0K       0K       0K        6
Stack (reserved)                      544K       0K       0K       0K       0K       0K       0K        1         reserved VM address space (unallocated)
Stack Guard                          56.1M       0K       0K       0K       0K       0K       0K        7
Untagged                             13.2M      96K      96K     608K       0K       0K       0K       24
__AUTH                               6023K    3629K     827K     339K       0K       0K       0K      624
__AUTH_CONST                        107.1M    67.7M       0K       0K       0K       0K       0K     1186
__CTF                                  824      824       0K       0K       0K       0K       0K        1
__DATA                               44.7M    13.0M    2289K    1323K       0K       0K       0K     1146
__DATA_CONST                         40.4M    22.9M      64K     176K       0K       0K       0K     1196
__DATA_DIRTY                         17.9M    8372K    2359K     733K       0K       0K       0K     1108
__FONT_DATA                           2352     2352       0K       0K       0K       0K       0K        1
__LINKEDIT                            1.6G   618.9M       0K       0K       0K       0K       0K        7
__OBJC_RO                           118.5M    77.4M       0K       0K       0K       0K       0K        1
__OBJC_RW                            2740K    2436K      36K      16K       0K       0K       0K        1
__TEXT                                1.5G   792.0M       0K       0K       0K       0K       0K     1284
__TPRO_CONST                          132K      48K      48K      36K       0K       0K       0K        4
mapped file                         656.7M    52.3M       0K      32K       0K       0K       0K      176
owned unmapped                       3792K       0K       0K     208K       0K       0K       0K       29
owned unmapped (graphics)            9552K    2944K    2944K    6608K       0K       0K       0K       42
page table in kernel                  769K     769K     769K       0K       0K       0K       0K        1
shared memory                        8448K    2768K    1648K    1152K       0K       0K       0K       32
unused but dirty shlib __DATA         688K     378K     378K     310K       0K       0K       0K      494
===========                        ======= ========    =====  ======= ========   ======    =====  =======
TOTAL                               389.5G     1.8G   167.0M    75.6M       0K    7552K    18.2M     9274
TOTAL, minus reserved VM space      389.5G     1.8G   167.0M    75.6M       0K    7552K    18.2M     9274

                                          VIRTUAL   RESIDENT      DIRTY    SWAPPED ALLOCATION      BYTES DIRTY+SWAP          REGION
MALLOC ZONE                                  SIZE       SIZE       SIZE       SIZE      COUNT  ALLOCATED  FRAG SIZE  % FRAG   COUNT
===========                               =======  =========  =========  =========  =========  =========  =========  ======  ======
DefaultMallocZone_0x105b28000              252.5M     149.8M     141.5M      28.6M    1131293     114.1M      56.0M     33%     592
QuartzCore_0x10d150000                      8064K      7184K      7184K       432K      66582      4529K      3087K     41%     303
AttributeGraph_0x7b38392ca0                 4096K      2320K      1200K        48K      10474       374K       874K     71%       2
AttributeGraph graph data_0x10e9ec000       1104K       816K       816K       208K        362        80K       944K     93%      58
LSBindingEvaluator_0x105c04000               400K       320K       320K        80K          0         0K       400K    100%      16
objc-class_rw_t_0x105bd8000                  272K       272K       272K         0K       8760       205K        67K     25%      15
DefaultPurgeableMallocZone_0x10e318000       192K         0K         0K         0K          2       192K         0K      0%       2
SIQueryMallocZone_0x10d1b0000                  0K         0K         0K         0K          0         0K         0K      0%       0
===========                               =======  =========  =========  =========  =========  =========  =========  ======  ======
TOTAL                                      266.3M     160.4M     151.0M      29.3M    1217473     119.3M      61.0M     34%     988
"""#
}
