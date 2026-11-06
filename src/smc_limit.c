// SPDX-License-Identifier: GPL-2.0
// Set the Apple Silicon firmware charge limit (bfF0/bfD0/bfE0).
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/mfd/macsmc.h>

static int upper = 80;
static int lower = 75;
static int deactivate;
module_param(upper, int, 0444);
module_param(lower, int, 0444);
module_param(deactivate, int, 0444);
MODULE_PARM_DESC(upper, "Upper charge limit in percent");
MODULE_PARM_DESC(lower, "Lower (recharge) limit in percent");
MODULE_PARM_DESC(deactivate, "Deactivate the firmware limit instead of setting it");

static struct platform_device *smc_pdev;

static smc_key key4(const char *s)
{
	return ((u32)s[0] << 24) | ((u32)s[1] << 16) |
	       ((u32)s[2] << 8) | (u32)s[3];
}

static void dump_state(struct apple_smc *smc, const char *tag)
{
	u8 act = 0, chie = 0;
	u32 up = 0, lo = 0;
	u16 chls = 0;
	u64 chnc = 0;

	apple_smc_read_u8(smc, key4("bfF0"), &act);
	apple_smc_read_u32(smc, key4("bfD0"), &up);
	apple_smc_read_u32(smc, key4("bfE0"), &lo);
	apple_smc_read_u16(smc, key4("CHLS"), &chls);
	apple_smc_read_u64(smc, key4("CHNC"), &chnc);
	apple_smc_read_u8(smc, key4("CHIE"), &chie);

	pr_info("smc_limit: %s bfF0=%u bfD0=%u bfE0=%u CHLS=0x%04x CHNC=0x%016llx CHIE=%u\n",
		tag, act, up, lo, chls, chnc, chie);
}

static int __init smc_limit_init(void)
{
	struct device_node *np;
	struct apple_smc *smc;
	int ret;

	if (lower < 0 || upper > 100 || lower >= upper) {
		pr_err("smc_limit: invalid limits %d/%d\n", lower, upper);
		return -EINVAL;
	}

	np = of_find_compatible_node(NULL, NULL, "apple,smc");
	if (!np) {
		pr_err("smc_limit: no apple,smc node\n");
		return -ENODEV;
	}

	smc_pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (!smc_pdev) {
		pr_err("smc_limit: no platform device\n");
		return -ENODEV;
	}

	smc = dev_get_drvdata(&smc_pdev->dev);
	if (!smc) {
		pr_err("smc_limit: no drvdata\n");
		platform_device_put(smc_pdev);
		smc_pdev = NULL;
		return -ENODEV;
	}

	dump_state(smc, "before");

	if (deactivate) {
		ret = apple_smc_write_u8(smc, key4("bfF0"), 0);
		pr_info("smc_limit: deactivate ret=%d\n", ret);
		dump_state(smc, "after");
		return 0;
	}

	ret = apple_smc_write_u8(smc, key4("bfF0"), 0);
	pr_info("smc_limit: write bfF0=0 ret=%d\n", ret);

	ret = apple_smc_write_u32(smc, key4("bfD0"), (u32)upper);
	pr_info("smc_limit: write bfD0=%d ret=%d\n", upper, ret);
	if (ret < 0)
		goto out;

	ret = apple_smc_write_u32(smc, key4("bfE0"), (u32)lower);
	pr_info("smc_limit: write bfE0=%d ret=%d\n", lower, ret);
	if (ret < 0)
		goto out;

	ret = apple_smc_write_u8(smc, key4("bfF0"), 2);
	pr_info("smc_limit: write bfF0=2 ret=%d\n", ret);

out:
	dump_state(smc, "after");
	return 0;
}

static void __exit smc_limit_exit(void)
{
	if (smc_pdev)
		platform_device_put(smc_pdev);
}

module_init(smc_limit_init);
module_exit(smc_limit_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Set Apple Silicon firmware charge limit");
