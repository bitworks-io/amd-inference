# Resizable BAR (AMD Smart Access Memory)

FastLLM checks, each time it starts a model on the Vulkan engine, whether Resizable BAR appears to be off. If it is off,
FastLLM applies a workaround (`GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1`) so model buffers stay in the card's own memory and
models run at full speed. You can turn the workaround off in FastLLM's settings or with `-VulkanBarMitigation off`.

Turning on Resizable BAR in your PC's firmware (BIOS/UEFI) is AMD's recommended setup and may help further.

## How to turn it on (names vary by motherboard maker)
1. Restart the PC and open the firmware setup (usually Del or F2 during start-up).
2. Find **Above 4G Decoding** and set it to **Enabled**.
3. Find **Re-Size BAR Support** (or **Resizable BAR**, **Smart Access Memory**) and set it to **Enabled** or **Auto**.
4. Make sure the PC boots in **UEFI** mode (CSM/Legacy boot **off**). Changing this on an existing Windows install can
   stop it booting; check your motherboard maker's guide first.
5. Save and exit. In AMD Software: Adrenalin Edition, **Performance → Tuning** (or **Gaming → Graphics**) shows whether
   Smart Access Memory is active.

FastLLM does not change firmware settings and does not need administrator rights for this check.
