"""The area the app serves, read from the regions file the app bundles
(TransitCore/Sources/TransitCore/Regions/regions.json), so collected data covers exactly that area."""
import json
from pathlib import Path

FILE = Path(__file__).resolve().parents[1] / 'TransitCore/Sources/TransitCore/Regions/regions.json'

def boxes():
    """Every region's boxes as (south, west, north, east)."""
    document = json.loads(FILE.read_text(encoding='utf-8'))
    return [tuple(box) for region in document['regions'] for box in region['bounds']]

def contains(lat, lon):
    return any(south <= lat <= north and west <= lon <= east for south, west, north, east in boxes())

def envelope():
    """One box around every region, (south, north, west, east), for sources that take a single box."""
    all_boxes = boxes()
    return (min(b[0] for b in all_boxes), max(b[2] for b in all_boxes), min(b[1] for b in all_boxes), max(b[3] for b in all_boxes))
