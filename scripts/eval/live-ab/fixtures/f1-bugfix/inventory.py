"""In-memory inventory of stocked items."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Item:
    sku: str
    name: str
    quantity: int
    unit_cost: float


class Inventory:
    def __init__(self, items=None):
        self._items = {i.sku: i for i in (items or [])}

    def add(self, item):
        self._items[item.sku] = item

    def get(self, sku):
        return self._items.get(sku)

    def skus(self):
        return sorted(self._items)

    def quantities(self):
        return [self._items[s].quantity for s in self.skus()]

    def unit_costs(self):
        return [self._items[s].unit_cost for s in self.skus()]

    def total_value(self):
        return sum(i.quantity * i.unit_cost for i in self._items.values())
