import pytest

from stats import mean, median, spread
from inventory import Inventory, Item
from pricing import (
    markup_price,
    typical_quantity,
    average_unit_cost,
    cost_spread,
    restock_target,
)


def sample_inventory():
    return Inventory([
        Item("A-1", "bolt", 4, 0.25),
        Item("A-2", "nut", 6, 0.10),
        Item("A-3", "washer", 10, 0.05),
        Item("A-4", "screw", 20, 0.40),
        Item("A-5", "nail", 8, 0.20),
    ])


def test_mean_basic():
    assert mean([1, 2, 3, 4]) == 2.5


def test_mean_empty_raises():
    with pytest.raises(ValueError):
        mean([])


def test_median_odd_count():
    assert median([3, 1, 2]) == 2


def test_median_even_count():
    assert median([1, 2, 3, 4]) == 2.5


def test_spread():
    assert spread([2, 9, 4]) == 7


def test_markup_price():
    assert markup_price(2.00, 50) == 3.00


def test_average_unit_cost():
    assert average_unit_cost(sample_inventory()) == pytest.approx(0.20)


def test_cost_spread():
    assert cost_spread(sample_inventory()) == pytest.approx(0.35)


def test_total_value():
    assert sample_inventory().total_value() == pytest.approx(11.70)


def test_typical_quantity():
    assert typical_quantity(sample_inventory()) == 8


def test_restock_target():
    assert restock_target(sample_inventory()) == 16
